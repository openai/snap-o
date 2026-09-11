import Foundation
import SnapODeviceClient
import SwiftUI
import WebKit

actor InspectorHTTPService {
  struct Endpoint {
    let id: UUID
    let baseURL: URL
  }
}

actor InspectorService {
  nonisolated let registry: InspectorPluginRegistry
  private var apps: [InspectableApp]
  private let updates = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
  let endpoint = InspectorHTTPService.Endpoint(id: UUID(), baseURL: URL(string: "http://127.0.0.1:1234/")!)
  init(apps: [InspectableApp], registry: InspectorPluginRegistry) {
    self.apps = apps
    self.registry = registry
  }

  func discoverInspectors() async -> InspectorDiscoverySnapshot {
    InspectorDiscoverySnapshot(apps: apps)
  }

  func currentInspectors() -> InspectorDiscoverySnapshot {
    InspectorDiscoverySnapshot(apps: apps)
  }

  func changes() -> AsyncStream<Void> {
    updates.stream
  }

  func setApps(_ apps: [InspectableApp]) {
    self.apps = apps
    updates.continuation.yield(())
  }

  func openApp(_ input: OpenAppInput) async throws {}
  func inspectorEndpoint(
    for reference: InspectorServerReference, ownerID: UUID? = nil,
    invalidated: (@MainActor @Sendable () async -> Void)? = nil
  ) async throws -> InspectorHTTPService.Endpoint {
    endpoint
  }

  func releaseInspectorEndpoint(ownerID: UUID) {}

  func inspectorFrontend(
    for reference: InspectorServerReference, manifest: InspectorProcessMetadata, inspector: InspectorDescriptor
  ) async throws -> InspectorFrontendBundle {
    try Self.frontendFixture()
  }

  private static func frontendFixture() throws -> InspectorFrontendBundle {
    let directory = URL(fileURLWithPath: "../snapo-link-android/tweaks-core/frontend/dist")
    let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey])!
    var files: [String: Data] = [:]
    for case let file as URL in enumerator where try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
      files[String(file.path.dropFirst(directory.standardizedFileURL.path.count + 1))] = try Data(contentsOf: file)
    }
    return try InspectorFrontendBundle(files: files)
  }
}

@main
@MainActor
struct InspectorWebViewTests {
  static func eventually(_ message: String, _ condition: () async -> Bool) async throws {
    for _ in 0 ..< 500 {
      if await condition() { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    fatalError(message)
  }

  static func app(_ pid: Int, connectedKinds: [InspectorID]? = nil, kinds: [InspectorID] = [.network, .tweaks, .sample]) -> InspectableApp {
    InspectableApp(
      id: "phone:pid:\(pid)", name: "Demo \(pid)", packageName: "com.example.demo\(pid)",
      processName: "com.example.demo\(pid)", androidUserId: 0, deviceId: "phone", deviceDisplayTitle: "Phone",
      appIconBase64: nil, inspectors: kinds.map { kind in
        AppInspectorOption(kind: kind, server: InspectorServerReference(
          deviceId: "phone", socketName: "snapo_\(kind.rawValue)_\(pid)"
        ), protocolVersion: 4, isConnected: connectedKinds?.contains(kind) ?? true)
      }, manifest: testManifest(pid: pid, kinds: kinds)
    )
  }

  static func main() async throws {
    _ = NSApplication.shared
    let suite = "SnapOWebViewTests.\(UUID().uuidString)"
    let preferences = UserDefaults(suiteName: suite)!
    preferences.set(#"{"apps":[]}"#, forKey: "inspectorPreferences")
    defer { preferences.removePersistentDomain(forName: suite) }
    let first = app(10)
    let second = app(20)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.copyItem(at: URL(fileURLWithPath: "../inspectors/dist"), to: root)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.copyItem(
      at: URL(fileURLWithPath: "Tests/InspectorSelection/Fixtures/sample"),
      to: root.appendingPathComponent("sample")
    )
    let registry = try InspectorPluginRegistry(directory: root)
    precondition(registry.plugins.count == 2 && registry.plugin(for: .tweaks) == nil)
    let sockets = InspectorDiscovery.sockets(
      inProcNetUnix: "1: 00000002 00000000 00010000 0001 01 101 @snapo_sample_10",
      deviceID: "phone",
      definitions: registry.socketDefinitions
    )
    precondition(sockets.first?.kind == .sample && sockets.first?.pid == 10)
    let service = InspectorService(apps: [first, second], registry: registry)
    let model = InspectorHostModel(service: service, preferences: preferences)
    let hosting = NSHostingView(rootView: InspectorWebView(model: model))
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
      styleMask: [.borderless], backing: .buffered, defer: false
    )
    window.contentView = hosting
    window.orderBack(nil)
    defer { model.stop()
      window.orderOut(nil)
    }
    try await eventually("Network should load after discovery") {
      model.inspectorApps.count == 2 && model.isPageReady && model.webContainer?.webView.superview != nil
    }
    let network = model.webContainer!.webView
    let networkOrigin = network.url!.host
    try await eventually("Packaged Network JavaScript should render") {
      await (try? network.evaluateJavaScript("document.querySelector('#root').childElementCount > 0") as? Bool) == true
    }
    let canCreateSession = try await network.evaluateJavaScript("isSecureContext && typeof crypto.randomUUID === 'function'") as? Bool
    precondition(canCreateSession == true, "The frontend needs a secure origin for session IDs")
    _ = try await network.evaluateJavaScript("window.testState = 'network state'")
    let storageKey = "test-" + UUID().uuidString
    _ = try await network.evaluateJavaScript("localStorage.setItem('\(storageKey)', 'network value')")

    model.selectInspector(first, option: first.inspectors.first { $0.kind == .sample }!)
    try await eventually("A third plugin should load its index.html") { model.isPageReady && model.webContainer?.webView !== network }
    let sample = model.webContainer!.webView
    let marker = try await sample.evaluateJavaScript("document.querySelector('#sample-inspector').textContent") as? String
    precondition(marker == "Sample inspector", "Load the plugin HTML without assuming a root element")
    var sampleState: [String: Any]?
    try await eventually("The sample plugin should connect after its endpoint policy is installed") {
      sampleState = try? await sample.callAsyncJavaScript(
        "return await window.webkit.messageHandlers.snapoHost.postMessage({command:'hostState'});",
        arguments: [:], in: nil, contentWorld: .page
      ) as? [String: Any]
      return sampleState?["connected"] as? Bool == true
    }
    precondition((sampleState?["manifest"] as? [String: Any])?["pid"] as? Int == 10)
    precondition((sampleState?["inspector"] as? [String: Any])?["id"] as? String == "sample")
    let sampleStorage = try await sample.evaluateJavaScript("localStorage.getItem('\(storageKey)')")
    precondition(sampleStorage is NSNull)
    _ = try await sample.evaluateJavaScript("window.testState = 'sample state'")
    model.selectInspector(first, option: first.inspectors.first { $0.kind == .network }!)
    try await eventually("Network should return after the sample plugin") { network.superview != nil }
    model.selectInspector(first, option: first.inspectors.first { $0.kind == .sample }!)
    try await eventually("The sample plugin should reuse its view") { sample.superview != nil }
    let retainedSample = try await sample.evaluateJavaScript("window.testState") as? String
    precondition(retainedSample == "sample state")
    print("A third manifest discovers, loads, connects, and retains an isolated page")

    model.selectInspector(first, option: first.inspectors.first { $0.kind == .tweaks }!)
    try await eventually("Tweaks should load in its own view") {
      model.isPageReady && model.webContainer?.webView !== network && network.superview == nil
    }
    let tweaks = model.webContainer!.webView
    try await eventually("Packaged Tweaks JavaScript should render") {
      await (try? tweaks.evaluateJavaScript("document.querySelector('#root').childElementCount > 0") as? Bool) == true
    }
    let isolated = try await tweaks.evaluateJavaScript("localStorage.getItem('\(storageKey)')")
    precondition(isolated is NSNull, "Each inspector has separate storage")
    _ = try await tweaks.evaluateJavaScript("window.testState = 'tweaks state'")
    model.selectInspector(first, option: first.inspectors.first { $0.kind == .network }!)
    try await eventually("Switching back should reuse Network") {
      model.webContainer?.webView === network && network.superview != nil && tweaks.superview == nil
    }
    let networkState = try await network.evaluateJavaScript("window.testState") as? String
    precondition(networkState == "network state", "Keep renderer state when switching inspector types")
    model.selectApp(first)
    precondition(model.webContainer?.webView === network, "An unchanged selection keeps the same view")
    model.selectInspector(first, option: first.inspectors.first { $0.kind == .tweaks }!)
    try await eventually("Switching back should reuse Tweaks") { tweaks.superview != nil && model.isPageReady }
    let tweaksState = try await tweaks.evaluateJavaScript("window.testState") as? String
    precondition(tweaksState == "tweaks state")
    let hiddenNetworkState = try await network.callAsyncJavaScript(
      "return await window.webkit.messageHandlers.snapoHost.postMessage({command:'hostState'});",
      arguments: [:], in: nil, contentWorld: .page
    ) as? [String: Any]
    precondition(hiddenNetworkState?["connected"] as? Bool == false)
    print("Inspector types reuse their own view and receive inactive connection state")

    let tweaksOnly = app(30, kinds: [.tweaks])
    await service.setApps([first, second, tweaksOnly])
    try await eventually("Discover an app that only provides Tweaks") { model.inspectorApps.count == 3 }
    model.selectApp(tweaksOnly)
    let inactiveState = try await network.callAsyncJavaScript(
      "return await window.webkit.messageHandlers.snapoHost.postMessage({command:'hostState'});",
      arguments: [:], in: nil, contentWorld: .page
    ) as? [String: Any]
    precondition(inactiveState?["connected"] as? Bool == false)
    precondition((inactiveState?["manifest"] as? [String: Any])?["pid"] as? Int == 10)
    precondition((inactiveState?["inspector"] as? [String: Any])?["protocolVersion"] as? Int == 4)
    print("Hidden Network pages keep their protocol metadata when a different Tweaks app is selected")

    model.selectInspector(first, option: first.inspectors.first { $0.kind == .network }!)
    try await eventually("Network should remount") { network.superview != nil }
    var activeState: [String: Any]?
    try await eventually("Network should reconnect after remounting") {
      activeState = try? await network.callAsyncJavaScript(
        "return await window.webkit.messageHandlers.snapoHost.postMessage({command:'hostState'});",
        arguments: [:], in: nil, contentWorld: .page
      ) as? [String: Any]
      return activeState?["connected"] as? Bool == true
    }
    precondition(activeState?["baseURL"] as? String == "http://127.0.0.1:1234/")
    precondition((activeState?["inspector"] as? [String: Any])?["id"] as? String == "network")
    await service.setApps([app(10, connectedKinds: [.tweaks, .sample]), second])
    try await eventually("Cached metadata should remain visible while the selected inspector is disconnected") {
      model.isWaiting && model.inspectorApps.count == 2 && model.selectedInspectorApp?.id == first.id
    }
    precondition(model.webContainer?.webView === network && model.selectedInspectorApp?.inspectors.count == 3)
    let disconnectedState = try await network.callAsyncJavaScript(
      "return await window.webkit.messageHandlers.snapoHost.postMessage({command:'hostState'});",
      arguments: [:], in: nil, contentWorld: .page
    ) as? [String: Any]
    precondition(disconnectedState?["connected"] as? Bool == false && disconnectedState?["baseURL"] as? String == nil)
    precondition((disconnectedState?["manifest"] as? [String: Any])?["pid"] as? Int == 10)
    let retainedState = try await network.evaluateJavaScript("window.testState") as? String
    precondition(retainedState == "network state")
    await service.setApps([first, second])
    try await eventually("The same cached page should reconnect without reloading") {
      !model.isWaiting && model.webContainer?.webView === network
    }
    print("Disconnected inspector metadata keeps its row and page without retaining a live connection")
    _ = try await network.callAsyncJavaScript(
      """
      return await window.webkit.messageHandlers.snapoHost.postMessage({command:'setToolbar',payload:{revision:1000000,
        actions:[{type:'button',id:'test-clear',label:'Clear',icon:'clear',enabled:true}]}});
      """, arguments: [:], in: nil, contentWorld: .page
    )
    precondition(model.toolbarActions.count == 1)
    model.webContainer!.recoverFromEventOverflow()
    try await eventually("Page recovery should reload the inspector") { model.isPageReady }
    precondition(!model.toolbarActions.contains { $0.id == "test-clear" })
    let reloadedStorage = try await network.evaluateJavaScript("localStorage.getItem('\(storageKey)')") as? String
    precondition(reloadedStorage == "network value", "Recovery must preserve the storage origin")
    model.selectApp(second)
    let replacement = model.webContainer!.webView
    precondition(replacement !== network, "Changing the selected app replaces that inspector's view")
    try await eventually("The replacement page should load") { model.isPageReady && replacement.superview != nil }
    let stored = try await replacement.evaluateJavaScript("localStorage.getItem('\(storageKey)')")
    precondition(stored is NSNull, "Different providing apps cannot share inspector storage")
    _ = try await replacement.evaluateJavaScript("localStorage.removeItem('\(storageKey)')")
    precondition(network.superview == nil)
    let replacementState = try await replacement.evaluateJavaScript("typeof window.testState") as? String
    precondition(replacementState == "undefined")
    model.selectInspector(second, option: second.inspectors.first { $0.kind == .tweaks }!)
    precondition(model.webContainer?.webView !== tweaks, "Do not reuse another app's cached Tweaks page")
    try await eventually("The second app's Tweaks page should load") { model.isPageReady }
    print("Changing apps replaces cached pages and isolates inspector storage")

    model.selectApp(first)
    model.selectApp(second)
    model.selectApp(first)
    try await eventually("Rapid selection should load only the final page") {
      model.isPageReady && model.selectedInspectorApp?.id == first.id && model.webContainer?.webView.superview != nil
    }
    let finalPage = model.webContainer!.webView
    precondition(finalPage.url?.host == networkOrigin, "Recreated pages must use the same provider origin")
    let restoredStorage = try await finalPage.evaluateJavaScript("localStorage.getItem('\(storageKey)')") as? String
    precondition(restoredStorage == "network value", "Provider preferences must survive container replacement")
    _ = try await finalPage.evaluateJavaScript("localStorage.removeItem('\(storageKey)')")
    model.stop()
    try await eventually("Stopping the host should unmount the active page") { finalPage.superview == nil }
    print("Rapid selection and shutdown leave no obsolete page mounted")
    try await testSecurity()
    try await testFrontendSources(registry: registry, preferences: preferences)
    try await testInvalidBundledFrontend(registry: registry, root: root, preferences: preferences)
  }

  static func testInvalidBundledFrontend(registry: InspectorPluginRegistry, root: URL, preferences: UserDefaults) async throws {
    let entry = root.appendingPathComponent("sample/index.html")
    let original = try Data(contentsOf: entry)
    defer { try? original.write(to: entry) }
    try Data([0xFF]).write(to: entry)
    let provider = app(50, kinds: [.sample])
    let service = InspectorService(apps: [provider], registry: registry)
    let model = InspectorHostModel(service: service, preferences: preferences)
    defer { model.stop() }
    try await eventually("The invalid frontend provider should be discovered") { model.inspectorApps.count == 1 }
    model.selectInspector(provider, option: provider.inspectors[0])
    try await eventually("Bundled frontend validation errors must reach the native UI") {
      model.frontendError?.contains("invalid inspector frontend assets") == true
    }
    precondition(!model.isPageReady)
    print("Invalid bundled HTML reports its validation error without loading a page")
  }

  static func testFrontendSources(registry: InspectorPluginRegistry, preferences: UserDefaults) async throws {
    let html = """
    <!doctype html><html lang="en"><head>
    <script>try { eval('window.earlyEval = true'); } catch { window.earlyEval = false; }</script>
    <base href="https://example.test/">
    <link rel="stylesheet" href="./style.css"><script type="module" src="./main.js"></script>
    </head><body>Original HTML</body></html>
    """
    let bundle = try InspectorFrontendBundle(files: [
      "index.html": Data(html.utf8),
      "style.css": Data("body { color: rgb(1, 2, 3); }".utf8),
      "main.js": Data(
        "window.assetResult = (await import('./chunk.js')).value + await (await fetch(new URL('./data.txt', import.meta.url))).text();"
          .utf8
      ),
      "chunk.js": Data("export const value = 'module:';".utf8),
      "data.txt": Data("data".utf8)
    ])
    let container = InspectorWebContainer(bridge: InspectorWebBridge(), storageIdentifier: nil)
    container.start(frontend: bundle)
    let web = container.webView
    defer { container.stop() }
    try await eventually("APK assets must support module imports, CSS, and fetch") {
      await (try? web
        .evaluateJavaScript("window.assetResult === 'module:data' && getComputedStyle(document.body).color === 'rgb(1, 2, 3)'") as? Bool) ==
        true
    }
    let secure = try await web.evaluateJavaScript("isSecureContext && typeof crypto.randomUUID === 'function'") as? Bool
    precondition(secure == true)
    precondition(web.url?.scheme == InspectorAssetSchemeHandler.scheme && web.url?.path == "/index.html")
    let document = try await web.callAsyncJavaScript(
      """
      const response = await fetch(location.href);
      return {html: await response.text(), policy: response.headers.get('Content-Security-Policy'),
        earlyEval: window.earlyEval, baseURI: document.baseURI};
      """, arguments: [:], in: nil, contentWorld: .page
    ) as! [String: Any]
    precondition(document["html"] as? String == html, "Serve the original HTML bytes without injecting markup")
    precondition((document["policy"] as? String)?.contains("base-uri 'none'") == true)
    precondition(document["earlyEval"] as? Bool == false, "Apply CSP before the first script executes")
    precondition(document["baseURI"] as? String == web.url?.absoluteString, "CSP must reject an inspector-provided base URL")
    for invalid in ["", "https://example.com/", "file:///tmp/index.html", "http://user@localhost:1234/", "http://localhost:0/"] {
      precondition(InspectorWebPolicy.developmentURL(invalid) == nil)
    }
    let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SNAPO_WEB_SECURITY_FIXTURE_DIR"]!)
    let ports = try JSONDecoder().decode([String: Int].self, from: Data(contentsOf: directory.appendingPathComponent("ports.json")))
    let devURL = URL(string: "http://127.0.0.1:\(ports["allowed"]!)/dev")!
    let first = app(30, kinds: [.tweaks])
    let second = app(40, kinds: [.tweaks])
    let service = InspectorService(apps: [first, second], registry: registry)
    let model = InspectorHostModel(service: service, preferences: preferences)
    defer { model.stop() }
    try await eventually("Frontend providers should be discovered") { model.inspectorApps.count == 2 }
    model.selectInspector(first, option: first.inspectors[0])
    try await eventually("APK frontend should start without an override") {
      model.isPageReady && model.selectedInspectorApp?.id == first.id
    }
    precondition(model.developmentURL == nil)
    model.useDevelopmentServer(devURL)
    try await eventually("Development modules and HMR WebSockets must load") {
      guard model.isPageReady, let web = model.webContainer?.webView else { return false }
      return await (try? web.evaluateJavaScript("window.devLoaded && window.hmr === 'ok'") as? Bool) == true
    }
    let deniedURL = "http://127.0.0.1:\(ports["denied"]!)/dev-forbidden"
    let blocked = try await model.webContainer!.webView.callAsyncJavaScript(
      "try { await fetch(url); return false; } catch { return true; }",
      arguments: ["url": deniedURL], in: nil, contentWorld: .page
    ) as? Bool
    precondition(blocked == true, "A development override must not open other loopback servers")
    model.selectApp(second)
    precondition(model.developmentURL == nil, "Overrides belong to one provider")
    try await eventually("Another app should use its packaged frontend") { model.isPageReady }
    model.selectApp(first)
    precondition(model.developmentURL == devURL)
    try await eventually("Returning to the provider should restore its override") { model.isPageReady }
    model.useDevelopmentServer(nil)
    precondition(model.developmentURL == nil)
    try await eventually("Removing an override should restore the packaged frontend") { model.isPageReady }
    print("APK assets load modules, CSS, and data; development overrides support HMR and stay scoped to their provider")
  }

  static func testSecurity() async throws {
    let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SNAPO_WEB_SECURITY_FIXTURE_DIR"]!)
    let portsFile = directory.appendingPathComponent("ports.json")
    try await eventually("Security fixture should start") { FileManager.default.fileExists(atPath: portsFile.path) }
    let ports = try JSONDecoder().decode([String: Int].self, from: Data(contentsOf: portsFile))
    let allowed = URL(string: "http://127.0.0.1:\(ports["allowed"]!)/")!
    let denied = URL(string: "http://127.0.0.1:\(ports["denied"]!)/")!
    let (control, _) = try await URLSession.shared.data(from: denied.appendingPathComponent("control"))
    precondition(String(data: control, encoding: .utf8) == "ok", "The forbidden endpoint must be reachable without WebKit's policy")
    let fixture = try String(contentsOfFile: "Tests/InspectorSelection/Fixtures/hostile.html", encoding: .utf8)
      .replacingOccurrences(of: "__ALLOWED__", with: String(allowed.absoluteString.dropLast()))
      .replacingOccurrences(of: "__DENIED__", with: String(denied.absoluteString.dropLast()))
    let bridge = InspectorWebBridge()
    bridge.hostStateHandler = { InspectorConnectionState() }
    bridge.isActiveHandler = { false }
    let container = InspectorWebContainer(bridge: bridge, storageIdentifier: nil)
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
      styleMask: [.borderless],
      backing: .buffered,
      defer: false
    )
    let web = container.webView
    window.contentView = web
    window.orderBack(nil)
    defer { container.stop()
      window.orderOut(nil)
    }
    try container.start(frontend: InspectorFrontendBundle(files: ["index.html": Data(fixture.utf8)]))
    try await eventually("Hostile fixture should execute only after the initial policy is installed") {
      await (try? web.evaluateJavaScript("typeof window.attack === 'function'") as? Bool) == true
    }
    _ = try await web.callAsyncJavaScript("return await window.startup", arguments: [:], in: nil, contentWorld: .page)
    let logURL = allowed.appendingPathComponent("requests")
    let (initial, _) = try await URLSession.shared.data(from: logURL)
    let initialRequests = try JSONSerialization.jsonObject(with: initial) as! [[String: Any]]
    precondition(
      initialRequests.count == 1 && initialRequests[0]["path"] as? String == "/control",
      "No endpoint is allowed during startup"
    )
    try await container.allowEndpoint(allowed)
    let result = try await web
      .callAsyncJavaScript("return await window.attack()", arguments: [:], in: nil, contentWorld: .page) as! [String: Any]
    for key in ["allowed", "allowedSSE", "allowedSocket", "dataImage"] {
      precondition(result[key] as? String == "ok", key)
    }
    for key in ["denied", "redirect", "deniedSSE", "deniedSocket", "worker", "eval", "removedPolicy"] {
      precondition(result[key] as? String == "blocked", key)
    }
    precondition(result["rtc"] as? String == "undefined" && result["uuid"] as? String == "function")
    try await Task.sleep(for: .milliseconds(200))
    let (log, _) = try await URLSession.shared.data(from: logURL)
    let requests = try JSONSerialization.jsonObject(with: log) as! [[String: Any]]
    precondition(
      requests.allSatisfy { $0["port"] as? Int == ports["allowed"] || $0["path"] as? String == "/control" },
      "Forbidden requests must not reach the other server, even through redirects or subresources"
    )
    let (connectionLog, _) = try await URLSession.shared.data(from: allowed.appendingPathComponent("connections"))
    let connections = try JSONDecoder().decode([Int].self, from: connectionLog)
    precondition(
      connections.count(where: { $0 == ports["denied"] }) == 1,
      "Preconnect must not establish a TCP connection to the forbidden endpoint"
    )
    print("WebKit blocks forbidden requests, redirects, subresources, workers, and WebRTC while preserving allowed streams")

    let rejected = try await web.callAsyncJavaScript(
      """
      const send = (command, payload) => window.webkit.messageHandlers.snapoHost.postMessage({command,payload});
      const results = await Promise.allSettled([
        send('copyText', {text:'synthetic'}),
        send('saveFile', {defaultPath:'synthetic.txt',data:'synthetic'}),
        send('openNativeColorPanel', {sessionId:'test',color:'#112233',revision:0}),
        send('setToolbar', {revision:1,actions:Array.from({length:12},(_,i)=>({id:String(i),label:'Action',type:'button',icon:'clear'}))}),
        send('setToolbar', {revision:1,actions:[{id:'search',label:'Search',type:'search',inputRevision:9223372036854775807}]}),
        send('copyText', {text:'x'.repeat(1048576)}), send('unknown', {})
      ]);
      return results.every(r=>r.status==='rejected');
      """, arguments: [:], in: nil, contentWorld: .page
    ) as? Bool
    precondition(rejected == true, "Hidden inspectors and invalid messages must not invoke native actions")
    let working = try await web.callAsyncJavaScript(
      "return await window.webkit.messageHandlers.snapoHost.postMessage({command:'hostState'})",
      arguments: [:],
      in: nil,
      contentWorld: .page
    ) as? [String: Any]
    precondition(working?["connected"] as? Bool == false, "Reject bad requests without disabling valid bridge calls")

    let otherConfiguration = WKWebViewConfiguration()
    otherConfiguration.websiteDataStore = .nonPersistent()
    otherConfiguration.userContentController.addScriptMessageHandler(
      bridge,
      contentWorld: .page,
      name: InspectorWebBridge.messageHandlerName
    )
    let otherAssets = InspectorAssetSchemeHandler(storageIdentifier: UUID(uuidString: web.url!.host!))
    otherAssets.bundle = try InspectorFrontendBundle(files: ["index.html": Data("<p>Other page</p>".utf8)])
    otherConfiguration.setURLSchemeHandler(otherAssets, forURLScheme: InspectorAssetSchemeHandler.scheme)
    let other = WKWebView(frame: .zero, configuration: otherConfiguration)
    other.load(URLRequest(url: web.url!))
    try await eventually("Other page should load") { !other.isLoading && other.url != nil }
    let foreign = try await other.callAsyncJavaScript(
      "try {await window.webkit.messageHandlers.snapoHost.postMessage({command:'hostState'});return false;}catch{return true;}",
      arguments: [:], in: nil, contentWorld: .page
    ) as? Bool
    precondition(foreign == true, "Even the same origin and URL in another WebView cannot use this bridge")
    otherConfiguration.userContentController.removeAllScriptMessageHandlers()
    other.stopLoading()
    print("The native bridge rejects foreign pages, hidden native actions, oversized payloads, and invalid toolbar revisions")

    let first = app(10)
    let scope = InspectorWebPolicy.storageIdentifier(app: first, inspector: .sample)
    precondition(scope != nil && scope != InspectorWebPolicy.storageIdentifier(app: app(20), inspector: .sample))
    precondition(scope != InspectorWebPolicy.storageIdentifier(app: first, inspector: .network))
    var restarted = app(11)
    restarted.manifest = first.manifest
    precondition(
      scope == InspectorWebPolicy.storageIdentifier(app: restarted, inspector: .sample),
      "Process IDs do not partition a provider's preferences"
    )
    restarted.manifest = nil
    precondition(InspectorWebPolicy.storageIdentifier(app: restarted, inspector: .sample) == nil, "Unknown providers use ephemeral storage")
    var nested: Any = "value"
    for _ in 0 ..< 10 {
      nested = ["nested": nested]
    }
    precondition(!InspectorWebBridge.validMessage(["command": "setToolbar", "payload": nested], command: "setToolbar"))
    for invalid in ["https://127.0.0.1:1234/", "http://localhost:1234/", "http://127.0.0.1:1234/path", "http://127.0.0.1:1234/?q=1"] {
      precondition(!InspectorWebPolicy.isInspectorEndpoint(URL(string: invalid)!))
    }
    let oldURL = web.url
    container.recoverFromEventOverflow()
    try await eventually("Recovery must replace the document identity") { web.url != oldURL && !web.isLoading }
    let stale = try await web.callAsyncJavaScript(
      """
      const current = location.href;
      history.replaceState(null, '', oldURL);
      try {
        await window.webkit.messageHandlers.snapoHost.postMessage({command:'hostState'});
        return false;
      } catch { return true; }
      finally { history.replaceState(null, '', current); }
      """, arguments: ["oldURL": oldURL!.absoluteString], in: nil, contentWorld: .page
    ) as? Bool
    precondition(stale == true, "A previous document URL must not regain bridge access on the same origin")
    container.stop()
    await container.finishStopping()
    precondition(web.url?.absoluteString == "about:blank", "A retired page must unload before releasing its endpoint")
    let retired = try await web.evaluateJavaScript("typeof window.attack") as? String
    precondition(retired == "undefined")
    print("Storage scopes follow providers; recovery changes document identity; retirement unloads old JavaScript")
  }
}
