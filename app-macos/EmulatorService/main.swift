import Foundation
import Security

/// All host state and SDK commands are confined to the worker queue.
final class EmulatorService: NSObject, EmulatorServiceProtocol, NSXPCListenerDelegate, @unchecked Sendable {
  private let worker = DispatchQueue(label: "com.openai.snapo.emulators")
  private let host = EmulatorHost()
  private let previewDiscovery = EmulatorPreviewDiscovery()
  private let clientRequirement: String?

  override init() {
    let appURL = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    var code: SecStaticCode?
    var requirement: SecRequirement?
    var text: CFString?
    if SecStaticCodeCreateWithPath(appURL as CFURL, [], &code) == errSecSuccess,
       let code,
       SecCodeCopyDesignatedRequirement(code, [], &requirement) == errSecSuccess,
       let requirement,
       SecRequirementCopyString(requirement, [], &text) == errSecSuccess {
      clientRequirement = text as String?
    } else {
      clientRequirement = nil
    }
    super.init()
  }

  func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
    guard connection.effectiveUserIdentifier == getuid(), let clientRequirement else { return false }
    connection.setCodeSigningRequirement(clientRequirement)
    connection.exportedInterface = NSXPCInterface(with: EmulatorServiceProtocol.self)
    connection.exportedObject = self
    connection.resume()
    return true
  }

  func snapshot(_ serials: [String], reply: @escaping @Sendable (Data?, String?) -> Void) {
    perform(reply: reply) { try $0.snapshot(serials: serials) }
  }

  func clipboardEndpoint(_ serial: String, reply: @escaping @Sendable (Data?, String?) -> Void) {
    worker.async { [self] in
      do {
        try reply(JSONEncoder().encode(host.clipboardEndpoint(serial: serial)), nil)
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
        let endpoint = try previewDiscovery.endpoint(for: serial)
        try reply(JSONEncoder().encode(endpoint), nil)
      } catch { reply(nil, error.localizedDescription) }
    }
  }

  func startADBServer(reply: @escaping @Sendable (Data?, String?) -> Void) {
    worker.async { [self] in
      do {
        try host.startADBServer()
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

let service = EmulatorService()
let listener = NSXPCListener.service()
listener.delegate = service
listener.resume()
