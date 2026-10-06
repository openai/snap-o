import Foundation

/// Inventory, endpoint discovery, and ADB startup each have their own serial queue.
final class AndroidHostService: NSObject, AndroidHostServiceProtocol, NSXPCListenerDelegate, @unchecked Sendable {
  private let worker = DispatchQueue(label: "com.openai.snapo.emulators")
  // Preview startup must not wait for SDK scans or emulator start/stop commands.
  private let endpointWorker = DispatchQueue(label: "com.openai.snapo.emulator-endpoints", qos: .userInitiated)
  private let adbWorker = DispatchQueue(label: "com.openai.snapo.adb")
  private let host = EmulatorHost()
  private let discovery = EmulatorGRPCDiscovery()
  #if !DEBUG
  private let clientRequirement = AndroidHostAuthentication.clientRequirement()
  #endif

  func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
    guard connection.effectiveUserIdentifier == getuid() else { return false }
    #if !DEBUG
    guard let clientRequirement else { return false }
    connection.setCodeSigningRequirement(clientRequirement)
    #endif
    connection.exportedInterface = AndroidHostInterface.make()
    connection.exportedObject = self
    connection.resume()
    return true
  }

  func snapshot(_ serials: [String], reply: @escaping @Sendable (Data?, String?) -> Void) {
    perform(reply: reply) { try $0.snapshot(serials: serials) }
  }

  func rotationEndpoint(_ serial: String, reply: @escaping @Sendable (Data?, String?) -> Void) {
    endpointWorker.async { [self] in
      do {
        try reply(JSONEncoder().encode(discovery.endpoint(for: serial, access: .rotation)), nil)
      } catch { reply(nil, "The emulator's rotation connection is unavailable.") }
    }
  }

  func clipboardEndpoint(_ serial: String, reply: @escaping @Sendable (Data?, String?) -> Void) {
    endpointWorker.async { [self] in
      do {
        try reply(JSONEncoder().encode(discovery.endpoint(for: serial, access: .clipboard)), nil)
      } catch { reply(nil, "The emulator's authenticated clipboard connection is unavailable.") }
    }
  }

  func start(_ avdID: String, coldBoot: Bool, serials: [String], reply: @escaping @Sendable (Data?, String?) -> Void) {
    perform(reply: reply) { try $0.start(avdID, coldBoot: coldBoot, serials: serials) }
  }

  func stop(_ avdID: String, serial: String, reply: @escaping @Sendable (Data?, String?) -> Void) {
    perform(reply: reply) { try $0.stop(avdID, serial: serial) }
  }

  func delete(_ avdID: String, serials: [String], reply: @escaping @Sendable (Data?, String?) -> Void) {
    perform(reply: reply) { try $0.delete(avdID, serials: serials) }
  }

  func previewEndpoint(_ serial: String, reply: @escaping @Sendable (Data?, String?) -> Void) {
    endpointWorker.async { [self] in
      do {
        let endpoint = try discovery.endpoint(for: serial)
        try reply(JSONEncoder().encode(endpoint), nil)
      } catch { reply(nil, error.localizedDescription) }
    }
  }

  func ensureADBServerRunning(_ environment: [String: String], reply: @escaping @Sendable (Data?, String?) -> Void) {
    adbWorker.async {
      do {
        let keys: Set = ["SNAPO_ADB", "ANDROID_HOME", "ANDROID_SDK_ROOT", "PATH"]
        let configuration = ProcessInfo.processInfo.environment.merging(environment.filter { keys.contains($0.key) }) { _, new in new }
        try ADBServer(environment: configuration).startIfNeeded()
        reply(Data(), nil)
      } catch { reply(nil, error.localizedDescription) }
    }
  }

  func controls(_ serial: String, native: Data, display: any EmulatorDisplayProvider, reply: @escaping @Sendable (Data?, String?) -> Void) {
    worker.async { [self] in
      do {
        let connection = try JSONDecoder().decode(EmulatorNativeConnection.self, from: native)
        try reply(JSONEncoder().encode(host.controls(serial: serial, native: connection, display: display)), nil)
      } catch { reply(nil, error.localizedDescription) }
    }
  }

  func control(
    _ serial: String, request: Data, display: any EmulatorDisplayProvider,
    reply: @escaping @Sendable (Data?, String?) -> Void
  ) {
    worker.async { [self] in
      do {
        let command = try JSONDecoder().decode(EmulatorControlRequest.self, from: request)
        try host.control(
          serial: serial, avdPath: command.avdPath, action: command.action.rawValue, native: command.native, display: display
        )
        reply(Data(), nil)
      } catch { reply(nil, error.localizedDescription) }
    }
  }

  private func perform(
    reply: @escaping @Sendable (Data?, String?) -> Void,
    action: @escaping @Sendable (EmulatorHost) throws -> EmulatorInventory
  ) {
    worker.async { [self] in
      do {
        try reply(JSONEncoder().encode(action(host)), nil)
      } catch {
        reply(nil, error.localizedDescription)
      }
    }
  }
}

let service = AndroidHostService()
let listener = NSXPCListener.service()
listener.delegate = service
listener.resume()
