import AppKit
import Foundation
import SnapODeviceClient
import WebKit

@MainActor
final class InspectorWebContainer: NSObject, WKNavigationDelegate, WKUIDelegate {
  private struct PendingPageEvent {
    let name: String
    let payload: Any
  }

  private static let maximumPendingPageEvents = 2048
  private static let maximumPageEventBatchSize = 64

  let id = UUID()
  let webView: WKWebView
  var pageReadinessChangedHandler: ((Bool) -> Void)?

  private let embeddedHTML: String?
  private let developmentURL: URL?
  static let pageOrigin = URL(string: "http://localhost/")
  private let bridge: InspectorWebBridge
  private var isStopped = false
  private var policyTask: Task<Void, Never>?
  private var policyGeneration = 0
  private var endpoint: URL?
  private var policyInstalled = false
  private var currentRuleList: WKContentRuleList?
  private var unloadNavigation: WKNavigation?
  private var documentURL = InspectorWebContainer.pageOrigin?.appendingPathComponent(UUID().uuidString)
  private var stopContinuation: CheckedContinuation<Void, Never>?
  private var unloadTask: Task<Void, Never>?
  private let ruleListIdentifier = "snapo.inspector." + UUID().uuidString
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

  init(bridge: InspectorWebBridge, plugin: InspectorPlugin, storageIdentifier: UUID?) {
    let configuration = WKWebViewConfiguration()
    embeddedHTML = plugin.resourceDirectory.flatMap {
      try? String(contentsOf: $0.appendingPathComponent("index.html"), encoding: .utf8)
    }
    developmentURL = Self.developmentURL(pluginID: plugin.id)
    self.bridge = bridge
    configuration.websiteDataStore = storageIdentifier.map { WKWebsiteDataStore(forIdentifier: $0) } ?? .nonPersistent()
    configuration.defaultWebpagePreferences.isLockdownModeEnabled = true
    configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
    configuration.preferences.isElementFullscreenEnabled = false
    configuration.allowsAirPlayForMediaPlayback = false
    configuration.mediaTypesRequiringUserActionForPlayback = .all
    configuration.userContentController.addScriptMessageHandler(
      bridge,
      contentWorld: .page,
      name: InspectorWebBridge.messageHandlerName
    )
    webView = WKWebView(frame: .zero, configuration: configuration)
    super.init()
    webView.navigationDelegate = self
    webView.uiDelegate = self
    webView.allowsLinkPreview = false
    bridge.webView = webView
    bridge.acceptsMessage = { [weak self] message in
      guard let self, !isStopped, policyInstalled, message.webView === webView,
            message.frameInfo.isMainFrame, let url = message.frameInfo.request.url, ownsPage(url) else { return false }
      let origin = message.frameInfo.securityOrigin
      guard let expected = developmentURL ?? Self.pageOrigin else { return false }
      return origin.protocol == expected.scheme && origin.host == expected.host
        && origin.port == (expected.port ?? 0)
    }
    bridge.colorPanelClosedHandler = { [weak self] id in
      self?.sendPageEvent(name: "host:color-closed", payload: id)
    }
    bridge.colorPanelChangedHandler = { [weak self] change in
      self?.sendPageEvent(name: "host:color-changed", payload: change)
    }
  }

  func start() {
    guard !isStopped else { return }
    policyTask = Task { [weak self] in
      guard let self else { return }
      do {
        try await allowEndpoint(nil)
        guard !isStopped else { return }
        loadInspector()
      } catch {
        // Never execute inspector code without an installed network policy.
        guard !isStopped else { return }
        webView.loadHTMLString("<p>Inspector security policy could not be loaded.</p>", baseURL: documentURL)
      }
    }
  }

  func allowEndpoint(_ endpoint: URL?) async throws {
    guard !isStopped else { throw CancellationError() }
    if policyInstalled, self.endpoint == endpoint { return }
    policyGeneration += 1
    let generation = policyGeneration
    let encoded = try InspectorWebPolicy.contentRules(endpoint: endpoint, developmentURL: developmentURL)
    let identifier = ruleListIdentifier + "." + String(generation)
    let list = try await WKContentRuleListStore.default().compileContentRuleList(
      forIdentifier: identifier, encodedContentRuleList: encoded
    )
    guard !Task.isCancelled, !isStopped, generation == policyGeneration, let list else {
      try? await WKContentRuleListStore.default().removeContentRuleList(forIdentifier: identifier)
      throw CancellationError()
    }
    let controller = webView.configuration.userContentController
    // The policies overlap during replacement; there is never an unfiltered interval.
    let previous = currentRuleList
    controller.add(list)
    if let previous { controller.remove(previous) }
    currentRuleList = list
    self.endpoint = endpoint
    policyInstalled = true
    if let previous { try? await WKContentRuleListStore.default().removeContentRuleList(forIdentifier: previous.identifier) }
  }

  func stop() {
    guard !isStopped else { return }
    isStopped = true
    isPageReady = false
    bridge.invalidate()
    policyTask?.cancel()
    policyGeneration += 1
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
    unloadTask = Task { [self] in
      await withCheckedContinuation { continuation in
        stopContinuation = continuation
        unloadNavigation = webView.loadHTMLString("", baseURL: nil)
      }
      webView.navigationDelegate = nil
      webView.uiDelegate = nil
    }
  }

  func finishStopping() async {
    await unloadTask?.value
    await policyTask?.value
    if let currentRuleList { try? await WKContentRuleListStore.default().removeContentRuleList(forIdentifier: currentRuleList.identifier) }
    await recoveryTask?.value
    recoveryTask = nil
    await bridge.finishStopping()
  }

  func closeNativeColorPanel() {
    bridge.cancelPresentation()
  }

  func recoverFromEventOverflow() {
    recoverPage()
  }

  func sendPageEvent(name: String, payload: some Encodable) {
    guard !isStopped, let payload = try? InspectorWebBridge.jsonObject(payload) else { return }
    enqueue(PendingPageEvent(name: name, payload: payload))
  }

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    if isStopped {
      guard navigation === unloadNavigation else { return }
      stopContinuation?.resume()
      stopContinuation = nil
      return
    }
    guard policyInstalled, let url = webView.url, ownsPage(url) else { return }
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
    if isStopped {
      stopContinuation?.resume()
      stopContinuation = nil
    } else {
      recoverPage()
    }
  }

  private func recoverPage() {
    guard !isStopped, recoveryTask == nil else { return }
    documentURL = nil
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
    if isStopped { return url.absoluteString == "about:blank" ? .allow : .cancel }
    guard navigationAction.targetFrame?.isMainFrame == true, !navigationAction.shouldPerformDownload else { return .cancel }
    if ownsPage(url), navigationAction.navigationType == .other { return .allow }
    if navigationAction.navigationType == .linkActivated, ["http", "https"].contains(url.scheme),
       url.user == nil, url.password == nil, navigationAction.sourceFrame.isMainFrame,
       let source = navigationAction.sourceFrame.request.url, ownsPage(source) {
      // Script-created clicks also arrive as linkActivated; require native confirmation.
      if await bridge.confirm("Open this link in your browser?", detail: url.absoluteString), !isStopped, ownsPage(source) {
        NSWorkspace.shared.open(url)
      }
    }
    return .cancel
  }

  func webView(
    _ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge,
    completionHandler: @escaping @MainActor @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
  ) {
    completionHandler(.cancelAuthenticationChallenge, nil)
  }

  func webView(
    _ webView: WKWebView, decideMediaCapturePermissionsFor origin: WKSecurityOrigin,
    initiatedBy frame: WKFrameInfo, type: WKMediaCaptureType
  ) async -> WKPermissionDecision {
    .deny
  }

  func webView(
    _ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
    initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable ([URL]?) -> Void
  ) {
    completionHandler(nil)
  }

  func webView(
    _ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
    initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable () -> Void
  ) {
    completionHandler()
  }

  func webView(
    _ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
    initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable (Bool) -> Void
  ) {
    completionHandler(false)
  }

  func webView(
    _ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
    initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable (String?) -> Void
  ) {
    completionHandler(nil)
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
    documentURL = Self.pageOrigin?.appendingPathComponent(UUID().uuidString)
    if let developmentURL {
      webView.load(URLRequest(url: developmentURL))
      return
    }

    guard let embeddedHTML else {
      webView.loadHTMLString(
        "<p style='font: 13px -apple-system; padding: 16px'>Inspector resources are unavailable.</p>",
        baseURL: documentURL
      )
      return
    }
    webView.loadHTMLString(InspectorWebPolicy.protectedHTML(embeddedHTML), baseURL: documentURL)
  }

  private func ownsPage(_ url: URL) -> Bool {
    if let developmentURL { return Self.hasSameOrigin(url, developmentURL) }
    var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
    components?.fragment = nil
    return components?.url == documentURL
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
