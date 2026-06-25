import Foundation
import WebKit

@MainActor
final class NetworkInspectorWebContainer: NSObject, WKNavigationDelegate {
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
  private let bridge: NetworkInspectorWebBridge
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

  init(bridge: NetworkInspectorWebBridge) {
    let configuration = WKWebViewConfiguration()
    let resourceDirectory = Bundle.main.resourceURL?.appendingPathComponent("NetworkInspector")
    embeddedHTML = resourceDirectory.flatMap(Self.makeEmbeddedHTML)
    developmentURL = Self.developmentURL()
    self.bridge = bridge
    configuration.userContentController.addScriptMessageHandler(
      bridge,
      contentWorld: .page,
      name: NetworkInspectorWebBridge.messageHandlerName
    )
    webView = WKWebView(frame: .zero, configuration: configuration)
    super.init()
    webView.navigationDelegate = self
  }

  func start() {
    loadInspector()
  }

  func stop() {
    recoveryTask?.cancel()
    recoveryTask = nil
    invalidatePageEventDelivery(clearPending: true)
    webView.stopLoading()
    webView.configuration.userContentController.removeScriptMessageHandler(
      forName: NetworkInspectorWebBridge.messageHandlerName,
      contentWorld: .page
    )
  }

  func recoverFromEventOverflow() {
    recoverPage()
  }

  func sendPageEvent(name: String, payload: some Encodable) {
    guard let payload = try? NetworkInspectorWebBridge.jsonObject(payload) else { return }
    enqueue(PendingPageEvent(name: name, payload: payload))
  }

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
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
    guard recoveryTask == nil else { return }
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

  private func enqueue(_ event: PendingPageEvent) {
    if pendingPageEvents.count + inFlightPageEventCount >= Self.maximumPendingPageEvents {
      // Dropping a CDP event would corrupt the page model. Reset the page so its
      // next stream starts from a fresh replay instead.
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
