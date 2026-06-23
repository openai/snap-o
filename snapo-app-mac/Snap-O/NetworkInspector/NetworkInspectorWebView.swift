import AppKit
import Observation
import SwiftUI
import WebKit

@Observable
@MainActor
final class NetworkInspectorSession {
  private(set) var model: NetworkInspectorWebViewModel?

  @ObservationIgnored private let deviceTracker: DeviceTracker
  @ObservationIgnored private var service: NetworkInspectorService?

  init(deviceTracker: DeviceTracker) {
    self.deviceTracker = deviceTracker
  }

  func startIfNeeded() {
    guard model == nil else { return }
    let service = NetworkInspectorService(deviceTracker: deviceTracker)
    self.service = service
    model = NetworkInspectorWebViewModel(service: service)
  }

  func stop() async {
    model?.stop()
    model = nil
    guard let service else { return }
    self.service = nil
    await service.stop()
  }
}

@Observable
@MainActor
final class NetworkInspectorWebViewModel: NSObject, WKNavigationDelegate {
  let webView: WKWebView
  private(set) var servers: [NetworkInspectorServer] = []
  private(set) var selectedServer: NetworkInspectorServer?
  private(set) var searchText = ""
  private(set) var sortNewestFirst = false
  private(set) var hasClearableItems = false
  private(set) var selectedRecordKind: String?
  private(set) var hasVisibleRecords = false

  @ObservationIgnored private let embeddedHTML: String?
  @ObservationIgnored private let developmentURL: URL?
  @ObservationIgnored private let bridge: NetworkInspectorWebBridge
  @ObservationIgnored private var outputTask: Task<Void, Never>?
  @ObservationIgnored private var recoveryTask: Task<Void, Never>?
  private(set) var isPageReady = false

  init(service: NetworkInspectorService) {
    let configuration = WKWebViewConfiguration()
    let bridge = NetworkInspectorWebBridge(service: service)
    let resourceDirectory = Bundle.main.resourceURL?.appendingPathComponent("NetworkInspector")
    let embeddedHTML = resourceDirectory.flatMap(Self.makeEmbeddedHTML)
    let developmentURL = Self.developmentURL()
    configuration.userContentController.addScriptMessageHandler(
      bridge,
      contentWorld: .page,
      name: NetworkInspectorWebBridge.messageHandlerName
    )

    self.embeddedHTML = embeddedHTML
    self.developmentURL = developmentURL
    self.bridge = bridge
    webView = WKWebView(frame: .zero, configuration: configuration)
    super.init()

    bridge.inspectorStateChangedHandler = { [weak self] state in
      self?.servers = state.servers
      self?.selectedServer = state.selectedServer.flatMap { selection in
        state.servers.first {
          $0.deviceId == selection.deviceId && $0.socketName == selection.socketName
        }
      }
      self?.searchText = state.searchText
      self?.sortNewestFirst = state.sortNewestFirst
      self?.hasClearableItems = state.hasClearableItems
      self?.selectedRecordKind = state.selectedRecordKind
      self?.hasVisibleRecords = state.hasVisibleRecords
    }
    webView.navigationDelegate = self
    loadInspector()

    outputTask = Task { [weak self] in
      let stream = await service.outputStream()
      for await output in stream {
        guard let self else { return }
        dispatch(output)
      }
    }
  }

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    isPageReady = true
  }

  func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
    isPageReady = false
  }

  func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
    guard recoveryTask == nil else { return }
    isPageReady = false
    recoveryTask = Task { [weak self] in
      guard let self else { return }
      await bridge.prepareForPageReload()
      guard !Task.isCancelled else {
        recoveryTask = nil
        return
      }
      loadInspector()
      recoveryTask = nil
    }
  }

  func webView(
    _ webView: WKWebView,
    decidePolicyFor navigationAction: WKNavigationAction
  ) async -> WKNavigationActionPolicy {
    guard navigationAction.targetFrame?.isMainFrame == true,
          let url = navigationAction.request.url
    else {
      return .cancel
    }

    if url.absoluteString == "about:blank" {
      return .allow
    }
    if let developmentURL, Self.hasSameOrigin(url, developmentURL) {
      return .allow
    }
    return .cancel
  }

  func stop() {
    recoveryTask?.cancel()
    recoveryTask = nil
    outputTask?.cancel()
    outputTask = nil
    webView.stopLoading()
    webView.configuration.userContentController.removeScriptMessageHandler(
      forName: NetworkInspectorWebBridge.messageHandlerName,
      contentWorld: .page
    )
  }

  func selectServer(_ server: NetworkInspectorServer) {
    selectedServer = server
    dispatch(
      eventName: "network:selected-server",
      payload: NetworkServerReference(deviceId: server.deviceId, socketName: server.socketName)
    )
  }

  func setSearchText(_ searchText: String) {
    self.searchText = searchText
    dispatch(eventName: "network:search-text", payload: searchText)
  }

  func setSortNewestFirst(_ sortNewestFirst: Bool) {
    self.sortNewestFirst = sortNewestFirst
    dispatch(eventName: "network:sort-newest-first", payload: sortNewestFirst)
  }

  func clearCompletedRecords() {
    hasClearableItems = false
    dispatch(eventName: "network:clear-completed", payload: true)
  }

  func copySelectedURL() {
    dispatch(eventName: "network:copy-selected-url", payload: true)
  }

  func copySelectedCurl() {
    dispatch(eventName: "network:copy-selected-curl", payload: true)
  }

  func exportVisibleRecordsAsHar() {
    dispatch(eventName: "network:export-visible-har", payload: true)
  }

  private func loadInspector() {
    if let developmentURL {
      webView.load(URLRequest(url: developmentURL))
      return
    }

    guard let embeddedHTML else {
      webView.loadHTMLString(
        "<p style='font: 13px -apple-system; padding: 16px'>Network Inspector resources are unavailable.</p>",
        baseURL: nil
      )
      return
    }
    webView.loadHTMLString(embeddedHTML, baseURL: nil)
  }

  private static func developmentURL() -> URL? {
    #if DEBUG
    guard let rawURL = ProcessInfo.processInfo.environment["SNAPO_NETWORK_INSPECTOR_DEV_URL"],
          let url = URL(string: rawURL),
          ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
          let host = url.host?.lowercased(),
          ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host)
    else {
      return nil
    }
    return url
    #else
    return nil
    #endif
  }

  private static func hasSameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
    lhs.scheme?.lowercased() == rhs.scheme?.lowercased()
      && lhs.host?.lowercased() == rhs.host?.lowercased()
      && lhs.port == rhs.port
  }

  private func dispatch(_ output: NetworkInspectorOutput) {
    guard isPageReady else { return }
    switch output {
    case .event(let event):
      dispatch(eventName: "network:event", payload: event)
    case .status(let status):
      dispatch(eventName: "network:status", payload: status)
    }
  }

  private func dispatch(eventName: String, payload: some Encodable) {
    guard let payload = try? NetworkInspectorWebBridge.jsonObject(payload) else { return }
    webView.callAsyncJavaScript(
      "window.dispatchEvent(new CustomEvent(`snapo:${eventName}`, { detail: payload }))",
      arguments: ["eventName": eventName, "payload": payload],
      in: nil,
      in: .page,
      completionHandler: nil
    )
  }

  private static func makeEmbeddedHTML(directory: URL) -> String? {
    let assetsDirectory = directory.appendingPathComponent("assets")
    guard let assets = try? FileManager.default.contentsOfDirectory(
      at: assetsDirectory,
      includingPropertiesForKeys: nil
    ),
      let styleURL = assets.first(where: { $0.pathExtension == "css" }),
      let scriptURL = assets.first(where: { $0.pathExtension == "js" }),
      let style = try? String(contentsOf: styleURL, encoding: .utf8),
      let script = try? String(contentsOf: scriptURL, encoding: .utf8)
    else {
      return nil
    }
    let escapedStyle = style.replacingOccurrences(
      of: "</style",
      with: "<\\/style",
      options: .caseInsensitive
    )
    let escapedScript = script.replacingOccurrences(
      of: "</script",
      with: "<\\/script",
      options: .caseInsensitive
    )

    return """
    <!doctype html>
    <html lang="en">
      <head>
        <meta charset="UTF-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1.0" />
        <title>Snap-O Network Inspector</title>
        <style>\(escapedStyle)</style>
      </head>
      <body>
        <div id="root"></div>
        <script>\(escapedScript)</script>
      </body>
    </html>
    """
  }
}

struct NetworkInspectorWebView: NSViewRepresentable {
  let model: NetworkInspectorWebViewModel

  func makeNSView(context: Context) -> WKWebView {
    model.webView
  }

  func updateNSView(_ nsView: WKWebView, context: Context) {}
}

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
    panel.nameFieldStringValue = input.defaultPath
    guard panel.runModal() == .OK, let url = panel.url else {
      return NetworkSaveFileResult(saved: false, path: nil)
    }
    try data.write(to: url, options: .atomic)
    return NetworkSaveFileResult(saved: true, path: url.path)
  }

  static func jsonObject(_ value: some Encodable) throws -> Any {
    let data = try JSONEncoder().encode(value)
    return try JSONSerialization.jsonObject(with: data)
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
