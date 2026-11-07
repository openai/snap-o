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

  func openADBTunnel(id: String, configuration: SSHConfiguration) async throws -> ADBTunnelHandle {
    let data = try JSONEncoder().encode(configuration)
    do {
      let response = try await request(waitForReplyOnCancellation: true) { proxy, reply in
        proxy.openADBTunnel(id, configuration: data, reply: reply)
      }
      let handle = try JSONDecoder().decode(ADBTunnelHandle.self, from: response)
      try Task.checkCancellation()
      return handle
    } catch {
      await closeADBTunnel(id: id)
      throw error
    }
  }

  func tunnelSocketFactory(id: String) -> @Sendable () throws -> FileHandle {
    let factory = TunnelSocketFactory(connection: connect(), id: id)
    return { try factory.open() }
  }

  func closeADBTunnel(id: String) async {
    _ = try? await request(waitForReplyOnCancellation: true) { proxy, reply in
      proxy.closeADBTunnel(id, reply: reply)
    }
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

/// The ADB socket factory is synchronous. Only socket setup crosses XPC; payload bytes do not.
private final class TunnelSocketReply: @unchecked Sendable {
  private let lock = NSLock()
  private let ready = DispatchSemaphore(value: 0)
  private var result: Result<FileHandle, Error>?
  private var finished = false

  func complete(_ value: Result<FileHandle, Error>) {
    lock.withLock {
      guard !finished else {
        if case .success(let handle) = value { try? handle.close() }
        return
      }
      finished = true
      result = value
      ready.signal()
    }
  }

  func wait() throws -> FileHandle {
    let status = ready.wait(timeout: .now() + 5)
    return try lock.withLock {
      defer { result = nil }
      if status == .success, let result { return try result.get() }
      finished = true
      if case .success(let handle) = result { try? handle.close() }
      throw AndroidHostClientError(message: "Opening the remote ADB socket timed out.")
    }
  }
}

/// NSXPCConnection supports concurrent proxy requests; this holder has no mutable state.
private final class TunnelSocketFactory: @unchecked Sendable {
  private let connection: NSXPCConnection
  private let id: String

  init(connection: NSXPCConnection, id: String) {
    self.connection = connection
    self.id = id
  }

  func open() throws -> FileHandle {
    let response = TunnelSocketReply()
    guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
      response.complete(.failure(AndroidHostClientError(message: error.localizedDescription)))
    }) as? AndroidHostServiceProtocol else {
      throw AndroidHostClientError(message: "Could not connect to the Android host service.")
    }
    proxy.connectADBTunnel(id) { handle, message in
      if let message {
        try? handle?.close()
        response.complete(.failure(AndroidHostClientError(message: message)))
      } else if let handle {
        response.complete(.success(handle))
      } else {
        response.complete(.failure(AndroidHostClientError(message: "The Android host service returned no socket.")))
      }
    }
    return try response.wait()
  }
}
