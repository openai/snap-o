import AppKit
import CryptoKit
import Foundation
import SnapODeviceClient
import WebKit

@MainActor
final class InspectorWebContainer: NSObject, WKNavigationDelegate {
  private struct PendingPageEvent {
    let name: String
    let payload: Any
  }

  private static let maximumPendingPageEvents = 2048
  private static let maximumPageEventBatchSize = 64

  let webView: WKWebView
  var pageReadinessChangedHandler: ((Bool) -> Void)?

  private let embeddedHTML: String?
  private let developmentURL: URL?
  static let pageOrigin = URL(string: "http://localhost/")
  private let bridge: InspectorWebBridge
  private var isStopped = false
  private var recoveryTask: Task<Void, Never>?
  private var pendingPageEvents: [PendingPageEvent] = []
  private var pageEventDeliveryGeneration: UInt = 0
  private var inFlightPageEventCount = 0
  private var isPageEventBatchInFlight = false
  private var isPageReady = false {
    didSet {
      guard isPageReady != oldValue else { return }
      pageReadinessChangedHandler?(isPageReady)
    }
  }

  init(bridge: InspectorWebBridge, plugin: InspectorPlugin) {
    let configuration = WKWebViewConfiguration()
    embeddedHTML = plugin.resourceDirectory.flatMap {
      try? String(contentsOf: $0.appendingPathComponent("index.html"), encoding: .utf8)
    }
    developmentURL = Self.developmentURL(pluginID: plugin.id)
    self.bridge = bridge
    let inspectorID = "com.openai.snap-o.inspector.\(plugin.id.rawValue)"
    let bytes = Array(SHA256.hash(data: Data(inspectorID.utf8)).prefix(16))
    let identifier = UUID(uuid: (
      bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
      bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
    ))
    configuration.websiteDataStore = WKWebsiteDataStore(forIdentifier: identifier)
    configuration.userContentController.addScriptMessageHandler(
      bridge,
      contentWorld: .page,
      name: InspectorWebBridge.messageHandlerName
    )
    webView = WKWebView(frame: .zero, configuration: configuration)
    super.init()
    webView.navigationDelegate = self
    bridge.colorPanelClosedHandler = { [weak self] id in
      self?.sendPageEvent(name: "host:color-closed", payload: id)
    }
    bridge.colorPanelChangedHandler = { [weak self] change in
      self?.sendPageEvent(name: "host:color-changed", payload: change)
    }
  }

  func start() {
    guard !isStopped else { return }
    loadInspector()
  }

  func stop() {
    guard !isStopped else { return }
    isStopped = true
    isPageReady = false
    bridge.invalidate()
    webView.navigationDelegate = nil
    recoveryTask?.cancel()
    closeNativeColorPanel()
    bridge.colorPanelChangedHandler = nil
    bridge.colorPanelClosedHandler = nil
    invalidatePageEventDelivery(clearPending: true)
    webView.stopLoading()
    webView.configuration.userContentController.removeScriptMessageHandler(
      forName: InspectorWebBridge.messageHandlerName,
      contentWorld: .page
    )
  }

  func finishStopping() async {
    await recoveryTask?.value
    recoveryTask = nil
    await bridge.finishStopping()
  }

  func closeNativeColorPanel() {
    bridge.closeNativeColorPanel()
  }

  func recoverFromEventOverflow() {
    recoverPage()
  }

  func sendPageEvent(name: String, payload: some Encodable) {
    guard !isStopped, let payload = try? InspectorWebBridge.jsonObject(payload) else { return }
    enqueue(PendingPageEvent(name: name, payload: payload))
  }

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    guard !isStopped else { return }
    isPageReady = true
    sendNextPageEventBatchIfNeeded()
  }

  func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
    let needsRecovery = (isPageReady || isPageEventBatchInFlight) && recoveryTask == nil
    isPageReady = false
    if needsRecovery {
      recoverPage()
    }
  }

  func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
    recoverPage()
  }

  private func recoverPage() {
    guard !isStopped, recoveryTask == nil else { return }
    isPageReady = false
    invalidatePageEventDelivery(clearPending: true)
    webView.stopLoading()
    recoveryTask = Task { [weak self] in
      guard let self else { return }
      await bridge.prepareForPageReload()
      guard !Task.isCancelled else {
        recoveryTask = nil
        return
      }
      pendingPageEvents.removeAll()
      loadInspector()
      recoveryTask = nil
    }
  }

  func webView(
    _ webView: WKWebView,
    decidePolicyFor navigationAction: WKNavigationAction
  ) async -> WKNavigationActionPolicy {
    guard let url = navigationAction.request.url else { return .cancel }
    if navigationAction.navigationType == .linkActivated,
       ["http", "https"].contains(url.scheme?.lowercased() ?? ""), !ownsPage(url) {
      NSWorkspace.shared.open(url)
      return .cancel
    }
    guard navigationAction.targetFrame?.isMainFrame == true else { return .cancel }
    if url.absoluteString == "about:blank" || ownsPage(url) { return .allow }

    return .cancel
  }

  private func enqueue(_ event: PendingPageEvent) {
    if pendingPageEvents.count + inFlightPageEventCount >= Self.maximumPendingPageEvents {
      // Reload if the page cannot keep up with host state changes.
      recoverPage()
      return
    }
    pendingPageEvents.append(event)
    sendNextPageEventBatchIfNeeded()
  }

  private func sendNextPageEventBatchIfNeeded() {
    guard isPageReady,
          !isPageEventBatchInFlight,
          !pendingPageEvents.isEmpty else { return }

    let batchSize = min(pendingPageEvents.count, Self.maximumPageEventBatchSize)
    let events = Array(pendingPageEvents.prefix(batchSize))
    pendingPageEvents.removeFirst(batchSize)
    isPageEventBatchInFlight = true
    inFlightPageEventCount = batchSize
    let generation = pageEventDeliveryGeneration
    let arguments = events.map { event in
      ["name": event.name, "payload": event.payload]
    }

    webView.callAsyncJavaScript(
      """
      for (const event of events) {
        window.dispatchEvent(new CustomEvent(`snapo:${event.name}`, { detail: event.payload }));
      }
      """,
      arguments: ["events": arguments],
      in: nil,
      in: .page
    ) { [weak self] result in
      let succeeded = switch result {
      case .success: true
      case .failure: false
      }
      Task { @MainActor [weak self] in
        self?.pageEventBatchDidFinish(
          generation: generation,
          succeeded: succeeded
        )
      }
    }
  }

  private func pageEventBatchDidFinish(generation: UInt, succeeded: Bool) {
    guard generation == pageEventDeliveryGeneration else { return }
    isPageEventBatchInFlight = false
    inFlightPageEventCount = 0
    guard succeeded else {
      recoverPage()
      return
    }
    sendNextPageEventBatchIfNeeded()
  }

  private func invalidatePageEventDelivery(clearPending: Bool) {
    pageEventDeliveryGeneration &+= 1
    isPageEventBatchInFlight = false
    inFlightPageEventCount = 0
    if clearPending {
      pendingPageEvents.removeAll()
    }
  }

  private func loadInspector() {
    if let developmentURL {
      webView.load(URLRequest(url: developmentURL))
      return
    }

    guard let embeddedHTML else {
      webView.loadHTMLString(
        "<p style='font: 13px -apple-system; padding: 16px'>Inspector resources are unavailable.</p>",
        baseURL: Self.pageOrigin
      )
      return
    }
    webView.loadHTMLString(embeddedHTML, baseURL: Self.pageOrigin)
  }

  private func ownsPage(_ url: URL) -> Bool {
    if let developmentURL { return Self.hasSameOrigin(url, developmentURL) }
    return url == Self.pageOrigin
  }

  private static func developmentURL(pluginID: InspectorID) -> URL? {
    #if DEBUG
    // Development overrides are local and scoped to one plugin.
    let key = "SNAPO_INSPECTOR_DEV_URL_" + pluginID.rawValue.uppercased().replacingOccurrences(of: "-", with: "_").replacingOccurrences(
      of: ".",
      with: "_"
    )
    guard let rawURL = ProcessInfo.processInfo.environment[key],
          let url = URL(string: rawURL),
          ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
          let host = url.host?.lowercased(),
          ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host),
          url.user == nil, url.password == nil else { return nil }
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
}
