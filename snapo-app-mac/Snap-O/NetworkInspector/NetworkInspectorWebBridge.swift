import AppKit
import SnapODeviceClient
import WebKit

@MainActor
final class NetworkInspectorWebBridge: NSObject, WKScriptMessageHandlerWithReply {
  static let messageHandlerName = "snapoNetwork"

  var inspectorStateChangedHandler: ((NetworkInspectorNativeState) -> Void)?

  private let service: NetworkInspectorService

  init(service: NetworkInspectorService) {
    self.service = service
  }

  func prepareForPageReload() async {
    await service.stopAllStreams()
  }

  func userContentController(
    _ userContentController: WKUserContentController,
    didReceive message: WKScriptMessage
  ) async -> (Any?, String?) {
    guard message.frameInfo.isMainFrame,
          let body = message.body as? [String: Any],
          let command = body["command"] as? String
    else {
      return (nil, NetworkInspectorError.invalidBridgeMessage.localizedDescription)
    }

    let payload = body["payload"]
    do {
      return try await (handle(command: command, payload: payload), nil)
    } catch {
      return (nil, error.localizedDescription)
    }
  }

  static func jsonObject(_ value: some Encodable) throws -> Any {
    let data = try JSONEncoder().encode(value)
    return try JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)
  }

  private func handle(command: String, payload: Any?) async throws -> Any? {
    switch command {
    case "appVersion":
      return Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
    case "listServers":
      return try await Self.jsonObject(service.listServers())
    case "loadBodies":
      let input = try Self.decode(NetworkLoadBodiesInput.self, from: payload)
      return try await Self.jsonObject(service.loadBodies(input))
    case "startStream":
      let input = try Self.decode(NetworkServerReference.self, from: payload)
      return try await Self.jsonObject(service.startStream(input))
    case "stopStream":
      let input = try Self.decode(StreamIdentifier.self, from: payload)
      await service.stopStream(input.streamId)
      return nil
    case "copyText":
      let input = try Self.decode(ClipboardText.self, from: payload)
      let pasteboard = NSPasteboard.general
      pasteboard.clearContents()
      pasteboard.setString(input.text, forType: .string)
      return nil
    case "openExternal":
      let input = try Self.decode(ExternalURL.self, from: payload)
      guard let url = URL(string: input.url),
            ["http", "https"].contains(url.scheme?.lowercased() ?? "")
      else {
        throw NetworkInspectorError.invalidBridgeMessage
      }
      NSWorkspace.shared.open(url)
      return nil
    case "saveFile":
      return try Self.jsonObject(saveFile(Self.decode(NetworkSaveFileInput.self, from: payload)))
    case "debugInspectorPreset":
      return "live"
    case "selectedDeviceChanged":
      return nil
    case "inspectorStateChanged":
      try inspectorStateChangedHandler?(
        Self.decode(NetworkInspectorNativeState.self, from: payload)
      )
      return nil
    default:
      throw NetworkInspectorError.invalidBridgeMessage
    }
  }

  private func saveFile(_ input: NetworkSaveFileInput) throws -> NetworkSaveFileResult {
    let data: Data
    switch input.encoding {
    case nil, "utf8":
      data = Data(input.data.utf8)
    case "base64":
      guard let decoded = Data(base64Encoded: input.data) else {
        throw NetworkInspectorError.invalidBridgeMessage
      }
      data = decoded
    default:
      throw NetworkInspectorError.invalidBridgeMessage
    }

    let panel = NSSavePanel()
    panel.canCreateDirectories = true
    panel.nameFieldStringValue = input.defaultPath
    if input.directoryKind == .har {
      panel.directoryURL = SaveLocation.defaultHARExportDirectory()
    }
    guard panel.runModal() == .OK, let url = panel.url else {
      return NetworkSaveFileResult(saved: false, path: nil)
    }
    try data.write(to: url, options: .atomic)
    if input.directoryKind == .har {
      SaveLocation.setLastHARExportDirectoryURL(url.deletingLastPathComponent())
    }
    return NetworkSaveFileResult(saved: true, path: url.path)
  }

  private static func decode<T: Decodable>(_ type: T.Type, from payload: Any?) throws -> T {
    guard let payload, JSONSerialization.isValidJSONObject(payload) else {
      throw NetworkInspectorError.invalidBridgeMessage
    }
    let data = try JSONSerialization.data(withJSONObject: payload)
    return try JSONDecoder().decode(type, from: data)
  }

  private struct StreamIdentifier: Decodable {
    let streamId: String
  }

  private struct ExternalURL: Decodable {
    let url: String
  }

  private struct ClipboardText: Decodable {
    let text: String
  }
}
