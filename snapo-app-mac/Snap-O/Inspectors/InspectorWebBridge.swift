import AppKit
import SnapODeviceClient
import WebKit

@MainActor
final class InspectorWebBridge: NSObject, WKScriptMessageHandlerWithReply, NSWindowDelegate {
  struct NativeColorPanelChange: Encodable {
    let color: String
    let sessionId: String
    let revision: Int
  }

  static let messageHandlerName = "snapoHost"

  private weak static var colorPanelOwner: InspectorWebBridge?

  weak var webView: WKWebView?
  var acceptsMessage: ((WKScriptMessage) -> Bool)?
  var isActiveHandler: (() -> Bool)?
  private var presentedSheet: NSWindow?
  private var nextPresentation = ContinuousClock.now
  static let maximumFileBytes = 64 * 1024 * 1024

  var hostStateHandler: (() -> InspectorConnectionState)?
  var toolbarHandler: ((InspectorToolbar) throws -> Void)?
  var colorPanelChangedHandler: ((NativeColorPanelChange) -> Void)?
  var colorPanelClosedHandler: ((String) -> Void)?

  private var isStopped = false
  private var hasNativeRequest = false
  private var requests: [UUID: Task<Void, Never>] = [:]
  private var activeColorPanelSessionID: String?
  private var colorPanelRevision = 0

  func invalidate() {
    isStopped = true
    cancelPresentation()
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
    cancelPresentation()
    for task in requests.values {
      task.cancel()
    }
    await finishStopping()
  }

  func cancelPresentation() {
    closeNativeColorPanel()
    if let sheet = presentedSheet { sheet.sheetParent?.endSheet(sheet, returnCode: .cancel) }
  }

  private var presentationWindow: NSWindow? {
    guard !isStopped, isActiveHandler?() == true, NSApp.isActive,
          let view = webView, !view.isHiddenOrHasHiddenAncestor,
          let window = view.window, window.isVisible, window.isMainWindow || window.isKeyWindow else { return nil }
    return window
  }

  func confirm(_ message: String, detail: String = "") async -> Bool {
    guard let window = presentationWindow, window.attachedSheet == nil,
          presentedSheet == nil, ContinuousClock.now >= nextPresentation else { return false }
    nextPresentation = .now.advanced(by: .seconds(1))
    let alert = NSAlert()
    alert.messageText = message
    alert.informativeText = String(detail.prefix(2048))
    alert.addButton(withTitle: "Allow")
    alert.addButton(withTitle: "Cancel")
    alert.buttons.first?.keyEquivalent = ""
    alert.buttons.last?.keyEquivalent = "\r"
    presentedSheet = alert.window
    let response = await alert.beginSheetModal(for: window)
    presentedSheet = nil
    return response == .alertFirstButtonReturn && !Task.isCancelled && presentationWindow != nil
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
    guard !isStopped, requests.count < 8, acceptsMessage?(message) == true,
          let body = message.body as? [String: Any],
          let command = body["command"] as? String, Self.validMessage(body, command: command)
    else {
      return (nil, InspectorError.invalidBridgeMessage.localizedDescription)
    }

    let nativeRequest = ["saveFile", "copyText", "openNativeColorPanel"].contains(command)
    guard !nativeRequest || !hasNativeRequest else {
      return (nil, InspectorError.invalidBridgeMessage.localizedDescription)
    }
    if nativeRequest { hasNativeRequest = true }
    defer { if nativeRequest { hasNativeRequest = false } }
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
      guard let state = hostStateHandler?() else { throw InspectorError.invalidBridgeMessage }
      return try Self.jsonObject(state)
    case "setToolbar":
      let toolbar = try Self.decode(InspectorToolbar.self, from: payload)
      try toolbar.validate()
      try toolbarHandler?(toolbar)
      return nil
    case "openNativeColorPanel":
      let input = try Self.decode(NativeColorPanelInput.self, from: payload)
      guard isActiveHandler?() == true else { throw InspectorError.invalidBridgeMessage }
      if input.present != false {
        guard await confirm("Allow this inspector to open the color picker?") else { throw CancellationError() }
      }
      try Task.checkCancellation()
      try openNativeColorPanel(input)
      return nil
    case "closeNativeColorPanel":
      let input = try Self.decode(NativeColorPanelSessionInput.self, from: payload)
      if activeColorPanelSessionID == input.sessionId {
        closeNativeColorPanel()
      }
      return nil
    case "copyText":
      let input = try Self.decode(ClipboardText.self, from: payload)
      guard await confirm("Allow this inspector to copy text?", detail: "This replaces the current clipboard contents.") else {
        throw CancellationError()
      }
      try Task.checkCancellation()
      let pasteboard = NSPasteboard.general
      pasteboard.clearContents()
      pasteboard.setString(input.text, forType: .string)
      return nil
    case "saveFile":
      return try await Self.jsonObject(saveFile(Self.decode(InspectorSaveFileInput.self, from: payload)))
    default:
      throw InspectorError.invalidBridgeMessage
    }
  }

  private func openNativeColorPanel(_ input: NativeColorPanelInput) throws {
    guard input.color.count == 7 || input.color.count == 9,
          input.color.first == "#",
          let components = UInt32(input.color.dropFirst(), radix: 16),
          !input.sessionId.isEmpty, input.sessionId.utf8.count <= 100, input.revision >= 0
    else {
      throw InspectorError.invalidBridgeMessage
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

  private func saveFile(_ input: InspectorSaveFileInput) async throws -> InspectorSaveFileResult {
    guard let window = presentationWindow, window.attachedSheet == nil, presentedSheet == nil,
          ContinuousClock.now >= nextPresentation else { throw InspectorError.invalidBridgeMessage }
    nextPresentation = .now.advanced(by: .seconds(1))
    let data: Data
    switch input.encoding {
    case nil, "utf8":
      data = Data(input.data.utf8)
    case "base64":
      guard let decoded = Data(base64Encoded: input.data) else {
        throw InspectorError.invalidBridgeMessage
      }
      data = decoded
    default:
      throw InspectorError.invalidBridgeMessage
    }

    guard data.count <= Self.maximumFileBytes, input.defaultPath.utf8.count <= 1024 else {
      throw InspectorError.invalidBridgeMessage
    }
    let filename = URL(fileURLWithPath: input.defaultPath).lastPathComponent
    let isHAR = URL(fileURLWithPath: filename).pathExtension.lowercased() == "har"
    let panel = NSSavePanel()
    panel.canCreateDirectories = true
    panel.nameFieldStringValue = filename
    if isHAR {
      panel.directoryURL = SaveLocation.defaultHARExportDirectory()
    }
    presentedSheet = panel
    let response = await panel.beginSheetModal(for: window)
    presentedSheet = nil
    try Task.checkCancellation()
    guard presentationWindow != nil, response == .OK, let url = panel.url else {
      return InspectorSaveFileResult(saved: false, path: nil)
    }
    try data.write(to: url, options: .atomic)
    if isHAR {
      SaveLocation.setLastHARExportDirectoryURL(url.deletingLastPathComponent())
    }
    return InspectorSaveFileResult(saved: true, path: nil)
  }

  static func validMessage(_ body: [String: Any], command: String) -> Bool {
    let limit: Int
    switch command {
    case "saveFile": limit = maximumFileBytes * 4 / 3 + 4096
    case "copyText": limit = 1_048_576
    case "hostState", "setToolbar", "openNativeColorPanel", "closeNativeColorPanel": limit = 65536
    default: return false
    }
    var bytes = limit
    var nodes = 512
    func visit(_ value: Any, depth: Int) -> Bool {
      nodes -= 1
      guard nodes >= 0, depth <= 8 else { return false }
      if let text = value as? String {
        bytes -= text.utf8.count
        return bytes >= 0
      }
      if let object = value as? [String: Any] {
        guard object.count <= 64 else { return false }
        return object.allSatisfy { visit($0.key, depth: depth + 1) && visit($0.value, depth: depth + 1) }
      }
      if let array = value as? [Any] {
        return array.count <= 64 && array.allSatisfy { visit($0, depth: depth + 1) }
      }
      return value is NSNumber || value is NSNull
    }
    return visit(body, depth: 0)
  }

  private static func decode<T: Decodable>(_ type: T.Type, from payload: Any?) throws -> T {
    guard let payload, JSONSerialization.isValidJSONObject(payload) else {
      throw InspectorError.invalidBridgeMessage
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
