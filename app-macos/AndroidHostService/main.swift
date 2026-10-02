import Foundation

/// Emulator state stays on its worker queue; ADB startup has a separate serial queue.
final class AndroidHostService: NSObject, AndroidHostServiceProtocol, NSXPCListenerDelegate, @unchecked Sendable {
  private let worker = DispatchQueue(label: "com.openai.snapo.emulators")
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
    connection.exportedInterface = NSXPCInterface(with: AndroidHostServiceProtocol.self)
    connection.exportedObject = self
    connection.resume()
    return true
  }

  func snapshot(_ serials: [String], reply: @escaping @Sendable (Data?, String?) -> Void) {
    perform(reply: reply) { try $0.snapshot(serials: serials) }
  }

  func rotationEndpoint(_ serial: String, reply: @escaping @Sendable (Data?, String?) -> Void) {
    worker.async { [self] in
      do {
        try reply(JSONEncoder().encode(discovery.endpoint(for: serial, access: .rotation)), nil)
      } catch { reply(nil, "The emulator's rotation connection is unavailable.") }
    }
  }

  func clipboardEndpoint(_ serial: String, reply: @escaping @Sendable (Data?, String?) -> Void) {
    worker.async { [self] in
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
    worker.async { [self] in
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

  func controls(_ serial: String, reply: @escaping @Sendable (Data?, String?) -> Void) {
    worker.async { [self] in
      do {
        try reply(JSONEncoder().encode(host.controls(serial: serial)), nil)
      } catch { reply(nil, error.localizedDescription) }
    }
  }

  func control(_ serial: String, avdPath: String, action: String, reply: @escaping @Sendable (Data?, String?) -> Void) {
    worker.async { [self] in
      do {
        try host.control(serial: serial, avdPath: avdPath, action: action)
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
