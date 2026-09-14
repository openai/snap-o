import AppKit
import Foundation
import Network
@testable import Snap_O
import Testing
import WebKit

@Suite("Tool WebKit wiring")
@MainActor
struct ToolWebContainerTests {
  @Test("custom assets, request policy, bridge ownership, and retirement", .timeLimit(.minutes(1)))
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

    try await container.allowEndpoint(allowedURL)
    #expect(try await fetch(allowedURL, in: web))
    #expect(try await !fetch(deniedURL, in: web))
    #expect(try await !fetch(allowedURL.appendingPathComponent("redirect"), in: web))
    #expect(denied.paths.isEmpty, "Direct and redirected requests must not reach a different endpoint")
    try await container.allowEndpoint(nil)
    let requests = allowed.paths.count
    #expect(try await !fetch(allowedURL, in: web))
    #expect(allowed.paths.count == requests, "Retiring an endpoint revokes its allowance")

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
    let assets = try ToolAssetSchemeHandler(storageIdentifier: UUID(uuidString: #require(url.host)))
    assets.bundle = try ToolFrontendBundle(files: ["index.html": Data("<p>Foreign page</p>".utf8)])
    otherConfiguration.setURLSchemeHandler(assets, forURLScheme: ToolAssetSchemeHandler.scheme)
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
    #expect(web.url?.absoluteString == "about:blank", "Unload the page before releasing its endpoint")
    #expect(try await web.evaluateJavaScript("typeof window.events") as? String == "undefined")
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
        let headers = "Content-Length: 2\r\nAccess-Control-Allow-Origin: *\r\nCache-Control: no-store\r\nConnection: close\r\n\r\nok"
        connection.send(content: Data((response + headers).utf8), completion: .contentProcessed { _ in connection.cancel() })
      }
    }
  }
}
