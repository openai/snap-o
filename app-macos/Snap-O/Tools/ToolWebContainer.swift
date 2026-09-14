import AppKit
import Foundation
import WebKit

@MainActor
final class ToolWebContainer: NSObject, WKNavigationDelegate, WKUIDelegate {
  private struct PendingPageEvent {
    let name: String
    let payload: Any
  }

  private static let maximumPendingPageEvents = 2048
  private static let maximumPageEventBatchSize = 64

  let webView: WKWebView
  var pageReadinessChangedHandler: ((Bool) -> Void)?
  var pageLoadFailedHandler: ((String) -> Void)?

  private let schemeHandler: ToolSchemeHandler
  private let developmentURL: URL?
  private let bridge: ToolWebBridge
  private var isStopped = false
  private var policyTask: Task<Void, Never>?
  private var endpointID: UUID?
  private var policyInstalled = false
  private var documentURL: URL?
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

  init(
    bridge: ToolWebBridge,
    storageIdentifier: UUID?, developmentURL: URL? = nil
  ) {
    let configuration = WKWebViewConfiguration()
    schemeHandler = ToolSchemeHandler(developmentURL: developmentURL)
    self.developmentURL = developmentURL
    self.bridge = bridge
    configuration.websiteDataStore = storageIdentifier.map { WKWebsiteDataStore(forIdentifier: $0) } ?? .nonPersistent()
    configuration.defaultWebpagePreferences.isLockdownModeEnabled = true
    configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
    configuration.preferences.isElementFullscreenEnabled = false
    configuration.allowsAirPlayForMediaPlayback = false
    configuration.mediaTypesRequiringUserActionForPlayback = .all
    configuration.setURLSchemeHandler(schemeHandler, forURLScheme: ToolURL.scheme)
    configuration.userContentController.addScriptMessageHandler(
      bridge,
      contentWorld: .page,
      name: ToolWebBridge.messageHandlerName
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
      let expected = ToolURL.frontend
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

  func start(frontend: ToolFrontendBundle?) {
    guard !isStopped, policyTask == nil else { return }
    schemeHandler.bundle = frontend
    policyTask = Task { [weak self] in
      guard let self else { return }
      do {
        try await installPolicy()
        guard !isStopped else { return }
        loadTool()
      } catch {
        // Never execute tool code without an installed network policy.
        guard !isStopped else { return }
        pageLoadFailedHandler?("Tool security policy could not be loaded.")
      }
    }
  }

  func setServer(_ endpoint: ToolHTTPService.Endpoint?) {
    guard !isStopped, endpointID != endpoint?.id else { return }
    schemeHandler.authorize(endpoint)
    endpointID = endpoint?.id
  }

  private func installPolicy() async throws {
    let encoded = try ToolWebPolicy.contentRules(developmentURL: developmentURL)
    let list = try await WKContentRuleListStore.default().compileContentRuleList(
      forIdentifier: ruleListIdentifier, encodedContentRuleList: encoded
    )
    guard !Task.isCancelled, !isStopped, let list else {
      throw CancellationError()
    }
    webView.configuration.userContentController.add(list)
    policyInstalled = true
  }

  func stop() {
    guard !isStopped else { return }
    isStopped = true
    webView.isInspectable = false
    isPageReady = false
    bridge.invalidate()
    schemeHandler.invalidate()
    policyTask?.cancel()
    recoveryTask?.cancel()
    closeNativeColorPanel()
    bridge.colorPanelChangedHandler = nil
    bridge.colorPanelClosedHandler = nil
    invalidatePageEventDelivery(clearPending: true)
    webView.stopLoading()
    webView.configuration.userContentController.removeScriptMessageHandler(
      forName: ToolWebBridge.messageHandlerName,
      contentWorld: .page
    )
    webView.navigationDelegate = nil
    webView.uiDelegate = nil
    webView.loadHTMLString("", baseURL: nil)
  }

  func finishStopping() async {
    await policyTask?.value
    try? await WKContentRuleListStore.default().removeContentRuleList(forIdentifier: ruleListIdentifier)
    await recoveryTask?.value
    recoveryTask = nil
    await bridge.finishStopping()
  }

  func closeNativeColorPanel() {
    bridge.cancelPresentation()
  }

  func inspectInSafari() {
    guard !isStopped else { return }
    webView.isInspectable = true
    let alert = NSAlert()
    alert.messageText = "Inspect in Safari"
    alert.informativeText = "In Safari’s Develop menu, select this Mac, then Snap-O and this tool page. "
      + "If Develop is hidden, enable web developer features in Safari Settings → Advanced."
    alert.addButton(withTitle: "Open Safari")
    alert.addButton(withTitle: "Cancel")
    guard let window = webView.window else { return }
    alert.beginSheetModal(for: window) { response in
      guard response == .alertFirstButtonReturn,
            let safari = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Safari") else { return }
      NSWorkspace.shared.openApplication(at: safari, configuration: NSWorkspace.OpenConfiguration())
    }
  }

  func recoverFromEventOverflow() {
    recoverPage()
  }

  func sendPageEvent(name: String, payload: some Encodable) {
    guard !isStopped, let payload = try? ToolWebBridge.jsonObject(payload) else { return }
    enqueue(PendingPageEvent(name: name, payload: payload))
  }

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    guard !isStopped, policyInstalled, let url = webView.url, ownsPage(url) else { return }
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

  func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
    if !isStopped { pageLoadFailedHandler?(error.localizedDescription) }
  }

  func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
    if !isStopped { pageLoadFailedHandler?(error.localizedDescription) }
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
      loadTool()
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

  private func loadTool() {
    guard let entryURL = schemeHandler.entryURL else {
      pageLoadFailedHandler?("Tool resources are unavailable.")
      return
    }
    // Keep the storage origin stable, but reject bridge messages from previous documents.
    let url = entryURL
      .appending(queryItems: [URLQueryItem(name: "document", value: UUID().uuidString)])
    documentURL = url
    webView.load(URLRequest(url: url))
  }

  private func ownsPage(_ url: URL) -> Bool {
    var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
    components?.fragment = nil
    return components?.url == documentURL
  }
}
