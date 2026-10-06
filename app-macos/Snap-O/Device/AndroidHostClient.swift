import Foundation

@MainActor
final class AndroidHostClient {
  private var connection: NSXPCConnection?
  private var generation = UUID()
  private var pending: [UUID: CheckedContinuation<Data, Error>] = [:]
  private var timeouts: [UUID: Task<Void, Never>] = [:]
  private let connectionFactory: @MainActor () -> NSXPCConnection
  private let displayReader: @Sendable (DeviceTarget) async throws -> String

  init(
    connectionFactory: @escaping @MainActor () -> NSXPCConnection = {
      let name = (Bundle.main.bundleIdentifier ?? "com.openai.snapo") + ".AndroidHostService"
      return NSXPCConnection(serviceName: name)
    },
    displayReader: @escaping @Sendable (DeviceTarget) async throws -> String = { target in
      try await ADBClient().bound(to: target).withTimeout(.seconds(2)).runShellString(
        deviceID: target.serial, command: "wm size; dumpsys display"
      )
    }
  ) {
    self.connectionFactory = connectionFactory
    self.displayReader = displayReader
  }

  func previewEndpoint(_ serial: String) async throws -> EmulatorGRPCEndpoint? {
    try await JSONDecoder().decode(EmulatorGRPCEndpoint?.self, from: request { proxy, reply in
      proxy.previewEndpoint(serial, reply: reply)
    })
  }

  func ensureADBServerRunning() async throws {
    let keys: Set = ["SNAPO_ADB", "ANDROID_HOME", "ANDROID_SDK_ROOT", "PATH"]
    let environment = ProcessInfo.processInfo.environment.filter { keys.contains($0.key) }
    _ = try await request { proxy, reply in proxy.ensureADBServerRunning(environment, reply: reply) }
  }

  func controls(target: DeviceTarget, native: EmulatorNativeConnection) async throws -> EmulatorControls {
    let connection = try JSONEncoder().encode(native)
    return try await withDisplayProbe(target: target) { display in
      try await JSONDecoder().decode(EmulatorControls.self, from: request(waitForReplyOnCancellation: true) { proxy, reply in
        proxy.controls(target.serial, native: connection, display: display, reply: reply)
      })
    }
  }

  func control(target: DeviceTarget, native: EmulatorNativeConnection, avdPath: String, action: EmulatorControlAction) async throws {
    let payload = try JSONEncoder().encode(EmulatorControlRequest(native: native, avdPath: avdPath, action: action))
    try await withDisplayProbe(target: target) { display in
      _ = try await request(waitForReplyOnCancellation: true) { proxy, reply in
        proxy.control(target.serial, request: payload, display: display, reply: reply)
      }
    }
  }

  private func withDisplayProbe<Value>(
    target: DeviceTarget, operation: (EmulatorDisplayProbe) async throws -> Value
  ) async throws -> Value {
    _ = try target.requireTransport(for: target.serial)
    let display = try EmulatorDisplayProbe(target: target, read: displayReader)
    return try await withTaskCancellationHandler {
      do {
        let value = try await operation(display)
        await display.shutdown()
        try Task.checkCancellation()
        _ = try target.requireTransport(for: target.serial)
        return value
      } catch {
        await display.shutdown()
        throw error
      }
    } onCancel: {
      Task { @MainActor in display.cancel() }
    }
  }

  func rotationEndpoint(serial: String) async throws -> EmulatorGRPCEndpoint {
    try await JSONDecoder().decode(EmulatorGRPCEndpoint.self, from: request { proxy, reply in
      proxy.rotationEndpoint(serial, reply: reply)
    })
  }

  func clipboardEndpoint(serial: String) async throws -> EmulatorGRPCEndpoint {
    try await JSONDecoder().decode(EmulatorGRPCEndpoint.self, from: request { proxy, reply in
      proxy.clipboardEndpoint(serial, reply: reply)
    })
  }

  func snapshot(serials: [String]) async throws -> EmulatorInventory {
    try await inventory { proxy, reply in proxy.snapshot(serials, reply: reply) }
  }

  func start(_ id: String, coldBoot: Bool, serials: [String]) async throws -> EmulatorInventory {
    try await inventory { proxy, reply in proxy.start(id, coldBoot: coldBoot, serials: serials, reply: reply) }
  }

  func stop(_ id: String, serial: String) async throws -> EmulatorInventory {
    try await inventory { proxy, reply in proxy.stop(id, serial: serial, reply: reply) }
  }

  func delete(_ id: String, serials: [String]) async throws -> EmulatorInventory {
    try await inventory { proxy, reply in proxy.delete(id, serials: serials, reply: reply) }
  }

  private func inventory(
    _ send: (any AndroidHostServiceProtocol, @escaping @Sendable (Data?, String?) -> Void) -> Void
  ) async throws -> EmulatorInventory {
    try await JSONDecoder().decode(EmulatorInventory.self, from: request(send))
  }

  func close(error: Error = CancellationError()) {
    connection?.invalidate()
    connection = nil
    generation = UUID()
    for id in Array(pending.keys) {
      complete(id, with: .failure(error))
    }
  }

  private func connect() -> NSXPCConnection {
    if let connection { return connection }
    let connection = connectionFactory()
    let generation = UUID()
    self.generation = generation
    connection.remoteObjectInterface = AndroidHostInterface.make()
    let disconnected: @Sendable () -> Void = { [weak self] in
      Task { @MainActor in
        guard let self, self.generation == generation else { return }
        self.close(error: AndroidHostClientError(message: "The Android host service disconnected. Try refreshing."))
      }
    }
    connection.invalidationHandler = disconnected
    connection.interruptionHandler = disconnected
    connection.resume()
    self.connection = connection
    return connection
  }

  private func request(
    waitForReplyOnCancellation: Bool = false,
    _ send: (any AndroidHostServiceProtocol, @escaping @Sendable (Data?, String?) -> Void) -> Void
  ) async throws -> Data {
    let id = UUID()
    let connection = connect()
    return try await withTaskCancellationHandler {
      try Task.checkCancellation()
      return try await withCheckedThrowingContinuation { continuation in
        pending[id] = continuation
        timeouts[id] = Task { [weak self] in
          do { try await Task.sleep(for: .seconds(45)) } catch { return }
          self?.complete(id, with: .failure(AndroidHostClientError(message: "The Android host service did not respond. Try refreshing.")))
        }
        guard let proxy = connection.remoteObjectProxyWithErrorHandler(Self.proxyErrorHandler { [weak self] message in
          self?.complete(id, with: .failure(AndroidHostClientError(message: message)))
        }) as? AndroidHostServiceProtocol else {
          complete(id, with: .failure(AndroidHostClientError(message: "Could not connect to the Android host service.")))
          return
        }
        send(proxy) { [weak self] data, message in
          Task { @MainActor in
            let result: Result<Data, Error> = if let message {
              .failure(AndroidHostClientError(message: message))
            } else if let data {
              .success(data)
            } else {
              .failure(AndroidHostClientError(message: "The Android host service returned no devices."))
            }
            self?.complete(id, with: result)
          }
        }
      }
    } onCancel: {
      guard !waitForReplyOnCancellation else { return }
      Task { @MainActor [weak self] in self?.complete(id, with: .failure(CancellationError())) }
    }
  }

  /// Handles XPC errors from any queue and delivers their messages on the main actor.
  static func proxyErrorHandler(
    completion: @escaping @MainActor @Sendable (String) -> Void
  ) -> @Sendable (Error) -> Void {
    { error in
      let message = error.localizedDescription
      Task { @MainActor in completion(message) }
    }
  }

  private func complete(_ id: UUID, with result: Result<Data, Error>) {
    timeouts.removeValue(forKey: id)?.cancel()
    pending.removeValue(forKey: id)?.resume(with: result)
  }
}

struct AndroidHostClientError: LocalizedError {
  let message: String
  var errorDescription: String? {
    message
  }
}
