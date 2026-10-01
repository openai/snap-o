import AppKit
import Foundation
@testable import Snap_O
import Synchronization
import Testing
import WebKit

@Suite(.timeLimit(.minutes(1)))
@MainActor
struct ToolWebContainerTests {
  #if DEBUG
  @Test
  func localInspectorEnablesDeveloperExtrasBeforeShowingAndDetaching() {
    let inspector = InspectorDouble()
    let delegate = NSObject()
    var enabled = false
    inspector.onShow = { #expect(enabled) }
    ToolWebInspector.show(inspector, delegate: delegate, enable: { enabled = true }, unavailable: {
      Issue.record("Supported inspector was rejected")
    })
    #expect(inspector.owner === delegate)
    #expect(inspector.calls == ["delegate", "show", "detach"])
  }

  @Test(arguments: [false, true])
  func unavailableInspectorDoesNotEnableDeveloperExtras(missing: Bool) {
    var unavailable = false
    ToolWebInspector.show(missing ? nil : NSObject(), delegate: NSObject(), enable: {
      Issue.record("Unsupported inspector enabled developer extras")
    }, unavailable: { unavailable = true })
    #expect(unavailable)
  }
  #endif

  @Test
  func pageEventsWaitForReadinessAndThePreviousBatch() throws {
    var queue = ToolPageEventQueue()
    for index in 0 ..< 65 {
      let enqueued = queue.enqueue(.init(name: "host:state", payload: index))
      #expect(enqueued)
    }
    let beforeReady = queue.next(isReady: false)
    #expect(beforeReady == nil)
    let first = queue.next(isReady: true)
    let batch = try #require(first)
    #expect(batch.events.compactMap { $0.payload as? Int } == Array(0 ..< 64))
    let duringDelivery = queue.next(isReady: true)
    #expect(duringDelivery == nil)
    let completed = queue.complete(generation: batch.generation)
    #expect(completed)
    let last = queue.next(isReady: true)
    #expect(last?.events.compactMap { $0.payload as? Int } == [64])
  }

  @Test
  func queueBoundsIncludeInFlightEventsAndResetRejectsStaleCallbacks() throws {
    var queue = ToolPageEventQueue()
    for index in 0 ..< 2048 {
      let enqueued = queue.enqueue(.init(name: "host:state", payload: index))
      #expect(enqueued)
    }
    let first = queue.next(isReady: true)
    let batch = try #require(first)
    let overflow = queue.enqueue(.init(name: "host:state", payload: 2048))
    #expect(!overflow)
    queue.reset()
    let enqueued = queue.enqueue(.init(name: "host:state", payload: "replacement"))
    #expect(enqueued)
    let replacement = queue.next(isReady: true)
    #expect(replacement?.events.first?.payload as? String == "replacement")
    let staleCompleted = queue.complete(generation: batch.generation)
    #expect(!staleCompleted && queue.isInFlight)
  }

  @Test
  func bridgeReturnsHostStateOnlyForAuthorizedMessages() async {
    let bridge = ToolWebBridge()
    var reads = 0
    bridge.hostStateHandler = { reads += 1
      return ToolConnectionState()
    }
    let rejected = await bridge.receive(["command": "hostState"], authorized: false)
    #expect(rejected.0 == nil && rejected.1 != nil)
    #expect(reads == 0)
    let accepted = await bridge.receive(["command": "hostState"], authorized: true)
    #expect((accepted.0 as? [String: Any])?["connected"] as? Bool == false)
    #expect(accepted.1 == nil && reads == 1)
    bridge.invalidate()
    let stopped = await bridge.receive(["command": "hostState"], authorized: true)
    #expect(stopped.0 == nil && stopped.1 != nil)
    #expect(reads == 1)
  }

  @Test(arguments: ["copyText", "saveFile", "openNativeColorPanel"], [false, true])
  func nativeCommandsRequireAnActiveVisibleWindow(command: String, active: Bool) async {
    let bridge = ToolWebBridge()
    bridge.isActiveHandler = { active }
    let result = await bridge.receive([
      "command": command,
      "payload": [
        "text": "fixture",
        "defaultPath": "fixture.txt",
        "data": "",
        "sessionId": "test",
        "color": "#112233",
        "revision": 0
      ]
    ], authorized: true)
    #expect(result.0 == nil && result.1 != nil)
  }

  @Test
  func documentAccessRequiresTheOwningViewFrameAndCurrentDocument() throws {
    let current = try #require(URL(string: "snapo://tool/index.html?document=current"))
    func accepts(
      ownsView: Bool = true, main: Bool = true, url: URL? = nil,
      scheme: String = "snapo", host: String = "tool", port: Int = 0
    ) -> Bool {
      ToolWebPolicy.acceptsMessage(
        ownsView: ownsView, isMainFrame: main, url: url ?? current, documentURL: current,
        origin: .init(scheme: scheme, host: host, port: port)
      )
    }
    #expect(accepts())
    #expect(accepts(url: URL(string: current.absoluteString + "#section")))
    #expect(!accepts(ownsView: false))
    #expect(!accepts(main: false))
    #expect(!accepts(scheme: "https"))
    #expect(!accepts(host: "other"))
    #expect(!accepts(port: 1234))
    #expect(!accepts(url: URL(string: "snapo://tool/index.html?document=previous")))
    #expect(!ToolWebPolicy.acceptsMessage(
      ownsView: true, isMainFrame: true, url: current, documentURL: nil, origin: .init(scheme: "snapo", host: "tool", port: 0)
    ))
  }

  @Test
  func bundledAssetsPreserveBytesAndInstallCSP() async throws {
    let html = Data("<script type=\"module\" src=\"./main.js\"></script>".utf8)
    let script = Data("window.fixture = true".utf8)
    let handler = ToolSchemeHandler()
    handler.bundle = try ToolFrontendBundle(files: ["index.html": html, "main.js": script])
    defer { handler.invalidate() }
    #expect(handler.entryURL == ToolURL.frontend.appendingPathComponent("index.html"))
    for (file, data, type) in [("index.html", html, "text/html; charset=utf-8"), ("main.js", script, "text/javascript; charset=utf-8")] {
      let request = SchemeTaskDouble(URLRequest(url: ToolURL.frontend.appendingPathComponent(file)))
      await handler.start(request)?.value
      #expect(request.failure == nil && request.finished)
      #expect(request.body == data)
      #expect(request.response?.value(forHTTPHeaderField: "Content-Type") == type)
      #expect(request.response?.value(forHTTPHeaderField: "Content-Security-Policy") == ToolWebPolicy.contentSecurityPolicy)
      #expect(request.response?.value(forHTTPHeaderField: "X-Content-Type-Options") == "nosniff")
    }
  }

  @Test(arguments: ["snapo://other/index.html", "snapo://tool:1234/index.html", "snapo://user@tool/index.html", "snapo://tool/api/items"])
  func rejectsForeignOriginsAndDisconnectedAPI(url: String) async throws {
    let handler = ToolSchemeHandler()
    defer { handler.invalidate() }
    let request = try SchemeTaskDouble(URLRequest(url: #require(URL(string: url))))
    await handler.start(request)?.value
    #expect(request.failure != nil)
    #expect(request.response == nil && request.body.isEmpty && !request.finished)
  }

  @Test(arguments: ["missing.html", "index.html"])
  func rejectsMissingAssetsAndNonGETRequests(file: String) async throws {
    let handler = ToolSchemeHandler()
    handler.bundle = try ToolFrontendBundle(files: ["index.html": Data("fixture".utf8)])
    defer { handler.invalidate() }
    var input = URLRequest(url: ToolURL.frontend.appendingPathComponent(file))
    if file == "index.html" { input.httpMethod = "POST" }
    let request = SchemeTaskDouble(input)
    await handler.start(request)?.value
    #expect(request.failure != nil && !request.finished)
  }

  @Test
  func developmentEntryUsesTheToolOriginAndRejectsRedirects() throws {
    let upstream = try #require(URL(string: "http://127.0.0.1:5173/dev/index.html"))
    let handler = ToolSchemeHandler(developmentURL: upstream)
    defer { handler.invalidate() }
    #expect(handler.entryURL?.absoluteString == "snapo://tool/dev/index.html")
    let response = try #require(HTTPURLResponse(
      url: upstream,
      statusCode: 302,
      httpVersion: nil,
      headerFields: ["Location": "https://example.com"]
    ))
    let task = URLSession.shared.dataTask(with: upstream)
    defer { task.cancel() }
    let called = Mutex(false)
    handler
      .urlSession(URLSession.shared, task: task, willPerformHTTPRedirection: response, newRequest: URLRequest(url: upstream)) { request in
        #expect(request == nil)
        called.withLock { $0 = true }
      }
    #expect(called.withLock { $0 })
  }
}

#if DEBUG
@MainActor
private final class InspectorDouble: NSObject {
  var calls: [String] = []
  var owner: NSObject?
  var onShow: (() -> Void)?
  @objc func setDelegate(_ value: NSObject) {
    owner = value
    calls.append("delegate")
  }

  @objc func show() {
    onShow?()
    calls.append("show")
  }

  @objc func detach() {
    calls.append("detach")
  }
}
#endif

@MainActor
final class SchemeTaskDouble: NSObject, @preconcurrency WKURLSchemeTask {
  let request: URLRequest
  var failure: Error?
  var response: HTTPURLResponse?
  var body = Data()
  var finished = false

  init(_ request: URLRequest) {
    self.request = request
  }

  func didReceive(_ response: URLResponse) {
    self.response = response as? HTTPURLResponse
  }

  func didReceive(_ data: Data) {
    body.append(data)
  }

  func didFinish() {
    finished = true
  }

  func didFailWithError(_ error: any Error) {
    failure = error
  }
}
