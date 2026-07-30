import AppKit
import SnapODeviceClient
import WebKit

@MainActor
final class NetworkInspectorWebBridge: NSObject, WKScriptMessageHandlerWithReply {
  struct NativeColorPanelChange: Encodable {
    let color: String
    let sessionId: String
  }

  static let messageHandlerName = "snapoNetwork"

  private weak static var colorPanelOwner: NetworkInspectorWebBridge?

  var inspectorStateChangedHandler: ((NetworkInspectorNativeState) -> Void)?
  var inspectorAppsChangedHandler: (([InspectableApp]) -> Void)?
  var tweaksStateChangedHandler: ((TweaksInspectorNativeState) -> Void)?
  var colorPanelChangedHandler: ((NativeColorPanelChange) -> Void)?

  private let service: NetworkInspectorService
  private var activeColorPanelSessionID: String?

  init(service: NetworkInspectorService) {
    self.service = service
  }

  func prepareForPageReload() async {
    closeNativeColorPanel()
    await service.stopAllStreams()
  }

  func closeNativeColorPanel() {
    activeColorPanelSessionID = nil
    guard Self.colorPanelOwner === self else { return }

    let panel = NSColorPanel.shared
    panel.setTarget(nil)
    panel.setAction(nil)
    Self.colorPanelOwner = nil
    panel.orderOut(nil)
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
    case "listInspectorApps":
      let apps = await service.listInspectorApps()
      inspectorAppsChangedHandler?(apps)
      return try Self.jsonObject(apps)
    case "listTweaks":
      let reference = try Self.decode(InspectorServerReference.self, from: payload)
      return try await Self.jsonObject(service.listTweaks(for: reference))
    case "updateTweaks":
      let input = try Self.decode(UpdateTweaksInput.self, from: payload)
      return try await Self.jsonObject(service.updateTweaks(input))
    case "openNativeColorPanel":
      try openNativeColorPanel(Self.decode(NativeColorPanelInput.self, from: payload))
      return nil
    case "startTweakStream":
      let reference = try Self.decode(InspectorServerReference.self, from: payload)
      return try await Self.jsonObject(service.startTweakStream(reference))
    case "stopTweakStream":
      let input = try Self.decode(StreamIdentifier.self, from: payload)
      await service.stopTweakStream(input.streamId)
      return nil
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
    case "tweaksStateChanged":
      try tweaksStateChangedHandler?(
        Self.decode(TweaksInspectorNativeState.self, from: payload)
      )
      return nil
    default:
      throw NetworkInspectorError.invalidBridgeMessage
    }
  }

  private func openNativeColorPanel(_ input: NativeColorPanelInput) throws {
    guard input.color.count == 7 || input.color.count == 9,
          input.color.first == "#",
          let components = UInt32(input.color.dropFirst(), radix: 16),
          !input.sessionId.isEmpty
    else {
      throw NetworkInspectorError.invalidBridgeMessage
    }

    let hasAlpha = input.color.count == 9
    let rgb = hasAlpha ? components >> 8 : components
    let alpha = hasAlpha ? CGFloat(components & 0xFF) / 255 : 1
    let color = NSColor(
      srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255,
      green: CGFloat((rgb >> 8) & 0xFF) / 255,
      blue: CGFloat(rgb & 0xFF) / 255,
      alpha: alpha
    )
    let panel = NSColorPanel.shared
    let shouldPresent = input.present ?? true
    guard shouldPresent || (Self.colorPanelOwner === self && panel.isVisible) else { return }

    let presentationWindow = NSApp.mainWindow
    let shouldCenterPanel = !panel.isVisible || Self.colorPanelOwner !== self
    panel.setTarget(nil)
    panel.setAction(nil)
    Self.colorPanelOwner?.activeColorPanelSessionID = nil
    panel.showsAlpha = true
    panel.isContinuous = true
    panel.color = color
    activeColorPanelSessionID = input.sessionId
    panel.setTarget(self)
    panel.setAction(#selector(colorPanelDidChange(_:)))
    Self.colorPanelOwner = self
    if shouldCenterPanel {
      positionColorPanel(panel, over: presentationWindow)
    }
    if shouldPresent {
      panel.makeKeyAndOrderFront(nil)
    }
  }

  private func positionColorPanel(_ panel: NSColorPanel, over window: NSWindow?) {
    guard let window else { return }

    let panelSize = panel.frame.size
    let centeredOrigin = NSPoint(
      x: window.frame.midX - panelSize.width / 2,
      y: window.frame.midY - panelSize.height / 2
    )
    guard let visibleFrame = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame else {
      panel.setFrameOrigin(centeredOrigin)
      return
    }

    let maximumX = max(visibleFrame.minX, visibleFrame.maxX - panelSize.width)
    let maximumY = max(visibleFrame.minY, visibleFrame.maxY - panelSize.height)
    panel.setFrameOrigin(
      NSPoint(
        x: min(max(centeredOrigin.x, visibleFrame.minX), maximumX),
        y: min(max(centeredOrigin.y, visibleFrame.minY), maximumY)
      )
    )
  }

  @objc
  private func colorPanelDidChange(_ panel: NSColorPanel) {
    guard Self.colorPanelOwner === self,
          let sessionId = activeColorPanelSessionID,
          let color = panel.color.usingColorSpace(.sRGB)
    else {
      return
    }

    let red = Int((min(max(color.redComponent, 0), 1) * 255).rounded())
    let green = Int((min(max(color.greenComponent, 0), 1) * 255).rounded())
    let blue = Int((min(max(color.blueComponent, 0), 1) * 255).rounded())
    let alpha = Int((min(max(color.alphaComponent, 0), 1) * 255).rounded())
    colorPanelChangedHandler?(
      NativeColorPanelChange(
        color: String(format: "#%02X%02X%02X%02X", red, green, blue, alpha),
        sessionId: sessionId
      )
    )
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

  private struct NativeColorPanelInput: Decodable {
    let color: String
    let sessionId: String
    let present: Bool?
  }
}
