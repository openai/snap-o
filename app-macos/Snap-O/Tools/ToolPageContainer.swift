import WebKit

/// The page operations used by the host. Tests can supply these without starting WebKit.
@MainActor
protocol ToolPageContainer: AnyObject {
  var webView: WKWebView { get }
  var pageReadinessChangedHandler: ((Bool) -> Void)? { get set }
  var pageLoadFailedHandler: ((String) -> Void)? { get set }
  func start(frontend: ToolFrontendBundle?)
  func setServer(_ endpoint: ToolHTTPService.Endpoint?)
  func sendPageEvent(name: String, payload: some Encodable)
  func stop()
  func finishStopping() async
  func closeNativeColorPanel()
  #if DEBUG
  func showWebInspector()
  #endif
}
