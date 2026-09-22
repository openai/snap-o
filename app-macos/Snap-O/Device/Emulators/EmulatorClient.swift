import Foundation

@MainActor
final class EmulatorClient {
  private var connection: NSXPCConnection?
  private var generation = UUID()
  private var pending: [UUID: CheckedContinuation<Data, Error>] = [:]
  private var timeouts: [UUID: Task<Void, Never>] = [:]

  func previewEndpoint(_ serial: String) async throws -> EmulatorGRPCEndpoint {
    try await JSONDecoder().decode(EmulatorGRPCEndpoint.self, from: request { proxy, reply in
      proxy.previewEndpoint(serial, reply: reply)
    })
  }

  func startADBServer() async throws {
    _ = try await request { proxy, reply in proxy.startADBServer(reply: reply) }
  }

  func controls(serial: String) async throws -> EmulatorControls {
    try await JSONDecoder().decode(EmulatorControls.self, from: request { proxy, reply in
      proxy.controls(serial, reply: reply)
    })
  }

  func control(serial: String, avdPath: String, action: EmulatorControlAction) async throws {
    _ = try await request { proxy, reply in
      proxy.control(serial, avdPath: avdPath, action: action.rawValue, reply: reply)
    }
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
    _ send: (any EmulatorServiceProtocol, @escaping @Sendable (Data?, String?) -> Void) -> Void
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
    let name = (Bundle.main.bundleIdentifier ?? "com.openai.snapo") + ".EmulatorService"
    let connection = NSXPCConnection(serviceName: name)
    let generation = UUID()
    self.generation = generation
    connection.remoteObjectInterface = NSXPCInterface(with: EmulatorServiceProtocol.self)
    let disconnected: @Sendable () -> Void = { [weak self] in
      Task { @MainActor in
        guard let self, self.generation == generation else { return }
        self.close(error: EmulatorClientError(message: "The emulator service disconnected. Try refreshing."))
      }
    }
    connection.invalidationHandler = disconnected
    connection.interruptionHandler = disconnected
    connection.resume()
    self.connection = connection
    return connection
  }

  private func request(
    _ send: (any EmulatorServiceProtocol, @escaping @Sendable (Data?, String?) -> Void) -> Void
  ) async throws -> Data {
    let id = UUID()
    let connection = connect()
    return try await withTaskCancellationHandler {
      try Task.checkCancellation()
      return try await withCheckedThrowingContinuation { continuation in
        pending[id] = continuation
        timeouts[id] = Task { [weak self] in
          do { try await Task.sleep(for: .seconds(45)) } catch { return }
          self?.complete(id, with: .failure(EmulatorClientError(message: "The emulator service did not respond. Try refreshing.")))
        }
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ [weak self] error in
          let message = error.localizedDescription
          Task { @MainActor in self?.complete(id, with: .failure(EmulatorClientError(message: message))) }
        }) as? EmulatorServiceProtocol else {
          complete(id, with: .failure(EmulatorClientError(message: "Could not connect to the emulator service.")))
          return
        }
        send(proxy) { [weak self] data, message in
          Task { @MainActor in
            let result: Result<Data, Error> = if let message {
              .failure(EmulatorClientError(message: message))
            } else if let data {
              .success(data)
            } else {
              .failure(EmulatorClientError(message: "The emulator service returned no devices."))
            }
            self?.complete(id, with: result)
          }
        }
      }
    } onCancel: {
      Task { @MainActor [weak self] in self?.complete(id, with: .failure(CancellationError())) }
    }
  }

  private func complete(_ id: UUID, with result: Result<Data, Error>) {
    timeouts.removeValue(forKey: id)?.cancel()
    pending.removeValue(forKey: id)?.resume(with: result)
  }
}

struct EmulatorClientError: LocalizedError {
  let message: String
  var errorDescription: String? {
    message
  }
}
