import AppKit
import Foundation
import Network
@testable import Snap_O
import Testing
import WebKit

@Suite("Tool WebKit wiring")
@MainActor
struct ToolWebContainerTests {
  @Test("custom assets, request policy, bridge ownership, and shutdown", .timeLimit(.minutes(1)))
  func containerLifecycle() async throws {
    let allowed = try ToolHTTPFixture()
    let denied = try ToolHTTPFixture()
    defer { allowed.stop()
      denied.stop()
    }
    let allowedURL = try await allowed.start()
    let deniedURL = try await denied.start()
    allowed.redirect = deniedURL
    let (_, control) = try await URLSession.shared.data(from: deniedURL)
    #expect((control as? HTTPURLResponse)?.statusCode == 200)
    denied.paths.removeAll()

    let html = """
    <script>
    window.events = [];
    addEventListener('snapo:host:state', e => events.push(e.detail));
    window.startup = fetch('\(allowedURL)').then(() => false, () => true);
    try { eval('window.earlyEval = true'); } catch { window.earlyEval = false; }
    </script>
    <script type="module" src="./main.js"></script>
    """
    let bundle = try ToolFrontendBundle(files: [
      "index.html": Data(html.utf8), "main.js": Data("window.moduleLoaded = true".utf8)
    ])
    let bridge = ToolWebBridge()
    bridge.hostStateHandler = { ToolConnectionState() }
    bridge.isActiveHandler = { false }
    let container = ToolWebContainer(bridge: bridge, storageIdentifier: nil)
    let web = container.webView
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
      styleMask: [.borderless],
      backing: .buffered,
      defer: false
    )
    window.contentView = web
    window.orderBack(nil)
    defer { container.stop()
      window.orderOut(nil)
    }
    var ready = false
    container.pageReadinessChangedHandler = { ready = $0 }
    container.sendPageEvent(name: "host:state", payload: "queued")
    container.start(frontend: bundle)
    container.start(frontend: nil)
    try await eventually { ready }
    let startup = try await web.callAsyncJavaScript("return await startup", arguments: [:], in: nil, contentWorld: .page)
    #expect(startup as? Bool == true, "Install the deny-all policy before executing tool scripts")
    #expect(allowed.paths.isEmpty)
    try await eventually {
      await (try? web.evaluateJavaScript("moduleLoaded && events[0] === 'queued'") as? Bool) == true
    }
    let served = try await web.callAsyncJavaScript(
      "return {html: await (await fetch(location.href)).text(), earlyEval}", arguments: [:], in: nil, contentWorld: .page
    ) as? [String: Any]
    #expect(served?["html"] as? String == html, "Serve original asset bytes")
    #expect(served?["earlyEval"] as? Bool == false, "Attach CSP before the first script")

    container.setServer(ToolHTTPService.Endpoint(
      id: UUID(), reference: ToolServerReference(deviceId: "phone", socketName: "snapo_sample_42"), adb: ADBClient()
    ))
    #expect(try await !fetch(allowedURL, in: web))
    #expect(try await !fetch(deniedURL, in: web))
    #expect(try await !fetch(allowedURL.appendingPathComponent("redirect"), in: web))
    #expect(denied.paths.isEmpty, "Direct and redirected requests must not reach a different endpoint")
    container.setServer(nil)
    let requests = allowed.paths.count
    #expect(try await !fetch(allowedURL, in: web))
    #expect(allowed.paths.count == requests, "Tool pages cannot contact loopback directly")

    let hostState = try await web.callAsyncJavaScript(
      "return await webkit.messageHandlers.snapoHost.postMessage({command:'hostState'})",
      arguments: [:], in: nil, contentWorld: .page
    ) as? [String: Any]
    #expect(hostState?["connected"] as? Bool == false)
    let hidden = try await web.callAsyncJavaScript(
      """
      const results = await Promise.allSettled(['copyText','saveFile','openNativeColorPanel'].map(command =>
        webkit.messageHandlers.snapoHost.postMessage({command, payload:{text:'fixture',defaultPath:'fixture.txt',data:'',sessionId:'test',color:'#112233',revision:0}})));
      return results.every(r => r.status === 'rejected');
      """, arguments: [:], in: nil, contentWorld: .page
    )
    #expect(hidden as? Bool == true, "Inactive pages cannot invoke native actions")

    let otherConfiguration = WKWebViewConfiguration()
    otherConfiguration.websiteDataStore = .nonPersistent()
    otherConfiguration.userContentController.addScriptMessageHandler(bridge, contentWorld: .page, name: ToolWebBridge.messageHandlerName)
    defer { otherConfiguration.userContentController.removeAllScriptMessageHandlers() }
    let url = try #require(web.url)
    let assets = ToolSchemeHandler()
    assets.bundle = try ToolFrontendBundle(files: ["index.html": Data("<p>Foreign page</p>".utf8)])
    otherConfiguration.setURLSchemeHandler(assets, forURLScheme: ToolURL.scheme)
    let other = WKWebView(frame: .zero, configuration: otherConfiguration)
    defer { other.stopLoading() }
    other.load(URLRequest(url: url))
    try await eventually { other.url != nil && !other.isLoading }
    #expect(try await bridgeRejected(in: other), "The same origin in another WebView cannot use this bridge")

    container.recoverFromEventOverflow()
    try await eventually { ready && web.url != url }
    let stale = try await web.callAsyncJavaScript(
      """
      const current = location.href;
      history.replaceState(null, '', oldURL);
      try { await webkit.messageHandlers.snapoHost.postMessage({command:'hostState'}); return false; }
      catch { return true; }
      finally { history.replaceState(null, '', current); }
      """, arguments: ["oldURL": url.absoluteString], in: nil, contentWorld: .page
    )
    #expect(stale as? Bool == true, "Recovery must revoke the old document's bridge access")
    #expect(try await !bridgeRejected(in: web), "The replacement document keeps bridge access")
    container.stop()
    await container.finishStopping()
    try await eventually { web.url?.absoluteString == "about:blank" && !web.isLoading }
    #expect(try await web.evaluateJavaScript("typeof window.events") as? String == "undefined")

    let development = ToolWebContainer(bridge: ToolWebBridge(), storageIdentifier: nil, developmentURL: allowedURL)
    defer { development.stop() }
    var developmentReady = false
    development.pageReadinessChangedHandler = { developmentReady = $0 }
    window.contentView = development.webView
    development.start(frontend: nil)
    try await eventually { developmentReady }
    #expect(development.webView.url?.scheme == "snapo")
    #expect(try await fetch(ToolURL.frontend.appending(path: "main.js"), in: development.webView))
    #expect(allowed.paths.contains("/main.js"), "Development files come from the local server")
    let developmentRequests = allowed.paths.count
    #expect(try await !fetch(ToolURL.api, in: development.webView))
    #expect(allowed.paths.count == developmentRequests, "API requests never go to the development server")
    #expect(try await !fetch(ToolURL.frontend.appending(path: "redirect"), in: development.webView))
    #expect(denied.paths.isEmpty, "Development redirects must not escape the selected server")
  }

  private func fetch(_ url: URL, in web: WKWebView) async throws -> Bool {
    try await web.callAsyncJavaScript(
      "try { return (await fetch(url, {signal: AbortSignal.timeout(2000)})).ok; } catch { return false; }",
      arguments: ["url": url.absoluteString], in: nil, contentWorld: .page
    ) as? Bool == true
  }

  private func bridgeRejected(in web: WKWebView) async throws -> Bool {
    try await web.callAsyncJavaScript(
      "try { await webkit.messageHandlers.snapoHost.postMessage({command:'hostState'}); return false; } catch { return true; }",
      arguments: [:], in: nil, contentWorld: .page
    ) as? Bool == true
  }

  private func eventually(_ predicate: () async -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(10)
    while ContinuousClock.now < deadline {
      if await predicate() { return }
      try await Task.sleep(for: .milliseconds(20))
    }
    Issue.record("WebKit fixture did not become ready within 10 seconds")
    throw CancellationError()
  }
}

/// Only the HTTP behavior needed to verify Snap-O's endpoint allowlist.
@MainActor
private final class ToolHTTPFixture {
  private let listener: NWListener
  private var connections: [NWConnection] = []
  var paths: [String] = []
  var redirect: URL?

  init() throws {
    let parameters = NWParameters.tcp
    parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
    listener = try NWListener(using: parameters)
  }

  func start() async throws -> URL {
    let (states, continuation) = AsyncStream<NWListener.State>.makeStream()
    listener.stateUpdateHandler = { continuation.yield($0) }
    listener.newConnectionHandler = { [weak self] connection in
      Task { @MainActor [weak self] in
        guard let self else { connection.cancel()
          return
        }
        connections.append(connection)
        connection.start(queue: .main)
        receive(connection)
      }
    }
    listener.start(queue: .main)
    for await state in states {
      switch state {
      case .ready:
        return try URL(string: "http://127.0.0.1:\(#require(listener.port).rawValue)/")!
      case .failed(let error): throw error
      case .cancelled: throw CancellationError()
      default: continue
      }
    }
    throw CancellationError()
  }

  func stop() {
    listener.cancel()
    connections.forEach { $0.cancel() }
  }

  private func receive(_ connection: NWConnection, pending: Data = Data()) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, complete, error in
      Task { @MainActor [weak self] in
        guard let self, error == nil, let data else { connection.cancel()
          return
        }
        let request = pending + data
        guard let text = String(data: request, encoding: .utf8), text.contains("\r\n\r\n") else {
          if !complete, request.count < 8192 { receive(connection, pending: request) } else { connection.cancel() }
          return
        }
        let path = String(text.split(separator: " ")[1])
        paths.append(path)
        let response = if path == "/redirect", let redirect {
          "HTTP/1.1 302 Found\r\nLocation: \(redirect)\r\n"
        } else {
          "HTTP/1.1 200 OK\r\n"
        }
        let headers = "Content-Type: text/html\r\nContent-Length: 2\r\nAccess-Control-Allow-Origin: *\r\nCache-Control: no-store\r\nConnection: close\r\n\r\nok"
        connection.send(content: Data((response + headers).utf8), completion: .contentProcessed { _ in connection.cancel() })
      }
    }
  }
}
