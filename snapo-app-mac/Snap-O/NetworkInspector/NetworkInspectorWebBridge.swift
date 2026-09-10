import AppKit
import SnapODeviceClient
import WebKit

@MainActor
final class NetworkInspectorWebBridge: NSObject, WKScriptMessageHandlerWithReply, NSWindowDelegate {
  struct NativeColorPanelChange: Encodable {
    let color: String
    let sessionId: String
    let revision: Int
  }

  static let messageHandlerName = "snapoNetwork"

  private weak static var colorPanelOwner: NetworkInspectorWebBridge?

  var hostStateHandler: (() -> InspectorConnectionState)?
  var toolbarHandler: ((InspectorToolbar) throws -> Void)?
  var colorPanelChangedHandler: ((NativeColorPanelChange) -> Void)?
  var colorPanelClosedHandler: ((String) -> Void)?

  private var isStopped = false
  private var requests: [UUID: Task<Void, Never>] = [:]
  private var activeColorPanelSessionID: String?
  private var colorPanelRevision = 0

  func invalidate() {
    isStopped = true
    closeNativeColorPanel()
    for task in requests.values {
      task.cancel()
    }
  }

  func finishStopping() async {
    let pending = Array(requests.values)
    for task in pending {
      await task.value
    }
  }

  func prepareForPageReload() async {
    closeNativeColorPanel()
  }

  func closeNativeColorPanel() {
    let sessionID = activeColorPanelSessionID
    activeColorPanelSessionID = nil
    if let sessionID { colorPanelClosedHandler?(sessionID) }
    guard Self.colorPanelOwner === self else { return }

    let panel = NSColorPanel.shared
    panel.setTarget(nil)
    panel.setAction(nil)
    panel.delegate = nil
    Self.colorPanelOwner = nil
    panel.orderOut(nil)
  }

  func userContentController(
    _ userContentController: WKUserContentController,
    didReceive message: WKScriptMessage
  ) async -> (Any?, String?) {
    guard !isStopped, message.frameInfo.isMainFrame,
          let body = message.body as? [String: Any],
          let command = body["command"] as? String
    else {
      return (nil, NetworkInspectorError.invalidBridgeMessage.localizedDescription)
    }

    let payload = body["payload"]
    let id = UUID()
    var reply: (Any?, String?) = (nil, CancellationError().localizedDescription)
    let task = Task { @MainActor in
      do {
        try Task.checkCancellation()
        let result = try await handle(command: command, payload: payload)
        try Task.checkCancellation()
        reply = (result, nil)
      } catch {
        reply = (nil, error.localizedDescription)
      }
    }
    requests[id] = task
    await task.value
    requests.removeValue(forKey: id)
    return reply
  }

  static func jsonObject(_ value: some Encodable) throws -> Any {
    let data = try JSONEncoder().encode(value)
    return try JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)
  }

  private func handle(command: String, payload: Any?) async throws -> Any? {
    switch command {
    case "hostState":
      guard let state = hostStateHandler?() else { throw NetworkInspectorError.invalidBridgeMessage }
      return try Self.jsonObject(state)
    case "setToolbar":
      let toolbar = try Self.decode(InspectorToolbar.self, from: payload)
      try toolbar.validate()
      try toolbarHandler?(toolbar)
      return nil
    case "openNativeColorPanel":
      try openNativeColorPanel(Self.decode(NativeColorPanelInput.self, from: payload))
      return nil
    case "closeNativeColorPanel":
      let input = try Self.decode(NativeColorPanelSessionInput.self, from: payload)
      if activeColorPanelSessionID == input.sessionId {
        closeNativeColorPanel()
      }
      return nil
    case "copyText":
      let input = try Self.decode(ClipboardText.self, from: payload)
      let pasteboard = NSPasteboard.general
      pasteboard.clearContents()
      pasteboard.setString(input.text, forType: .string)
      return nil
    case "saveFile":
      return try Self.jsonObject(saveFile(Self.decode(NetworkSaveFileInput.self, from: payload)))
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
    guard shouldPresent || (Self.colorPanelOwner === self && panel.isVisible
      && activeColorPanelSessionID == input.sessionId && input.revision >= colorPanelRevision) else { return }

    let presentationWindow = NSApp.mainWindow
    let shouldCenterPanel = !panel.isVisible || Self.colorPanelOwner !== self
    panel.setTarget(nil)
    panel.setAction(nil)
    if Self.colorPanelOwner !== self { Self.colorPanelOwner?.closeNativeColorPanel() }
    panel.showsAlpha = true
    panel.isContinuous = true
    panel.color = color
    activeColorPanelSessionID = input.sessionId
    colorPanelRevision = input.revision
    panel.delegate = self
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

  func windowWillClose(_ notification: Notification) {
    guard Self.colorPanelOwner === self else { return }
    closeNativeColorPanel()
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
        sessionId: sessionId,
        revision: colorPanelRevision
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

    let isHAR = URL(fileURLWithPath: input.defaultPath).pathExtension.lowercased() == "har"
    let panel = NSSavePanel()
    panel.canCreateDirectories = true
    panel.nameFieldStringValue = input.defaultPath
    if isHAR {
      panel.directoryURL = SaveLocation.defaultHARExportDirectory()
    }
    guard panel.runModal() == .OK, let url = panel.url else {
      return NetworkSaveFileResult(saved: false, path: nil)
    }
    try data.write(to: url, options: .atomic)
    if isHAR {
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

  private struct ClipboardText: Decodable {
    let text: String
  }

  private struct NativeColorPanelInput: Decodable {
    let color: String
    let sessionId: String
    let present: Bool?
    let revision: Int
  }

  private struct NativeColorPanelSessionInput: Decodable {
    let sessionId: String
  }
}
