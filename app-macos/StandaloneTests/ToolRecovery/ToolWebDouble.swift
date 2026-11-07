import Foundation
import WebKit

@MainActor
final class ToolWebBridge {
  var isActiveHandler: (() -> Bool)?
  var hostStateHandler: (() -> ToolConnectionState)?
  var toolbarHandler: ((ToolToolbar) throws -> Void)?
}

/// Exercise the real owners without creating a WKWebView or window.
@MainActor
final class ToolWebContainer: ToolPageContainer {
  var webView: WKWebView {
    preconditionFailure("Model tests must not request a native view")
  }

  #if DEBUG
  func showWebInspector() {}
  #endif
  var pageReadinessChangedHandler: ((Bool) -> Void)?
  var pageLoadFailedHandler: ((String) -> Void)?
  var cleanupGate: TestGate?
  private(set) var isStopped = false
  private(set) var didStart = false
  private(set) var didFinishStopping = false
  private(set) var serverUpdates = 0

  init(bridge: ToolWebBridge, storageIdentifier: UUID?, developmentURL: URL?) {}

  func start(frontend: ToolFrontendBundle?) {
    precondition(!isStopped)
    didStart = true
    pageReadinessChangedHandler?(true)
    testChanges.signal()
  }

  func stop() {
    isStopped = true
    testChanges.signal()
  }

  func finishStopping() async {
    await cleanupGate?.wait()
    didFinishStopping = true
    testChanges.signal()
  }

  func setServer(_ endpoint: ToolHTTPService.Endpoint?) {
    serverUpdates += 1
  }

  func sendPageEvent(name: String, payload: some Encodable) {}
  func closeNativeColorPanel() {}
}
