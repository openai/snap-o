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
  func inspectorEndpoint(for reference: InspectorServerReference) async throws -> InspectorHTTPService.Endpoint {
    endpoint
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
    precondition(registry.plugins.count == 3)
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
    try await eventually("Packaged Network JavaScript should render") {
      await (try? network.evaluateJavaScript("document.querySelector('#root').childElementCount > 0") as? Bool) == true
    }
    let canCreateSession = try await network.evaluateJavaScript("isSecureContext && typeof crypto.randomUUID === 'function'") as? Bool
    precondition(canCreateSession == true, "The frontend needs a secure localhost origin for session IDs")
    _ = try await network.evaluateJavaScript("window.testState = 'network state'")
    let storageKey = "test-" + UUID().uuidString
    _ = try await network.evaluateJavaScript("localStorage.setItem('\(storageKey)', 'network value')")

    model.selectInspector(first, option: first.inspectors.first { $0.kind == .sample }!)
    try await eventually("A third plugin should load its index.html") { model.isPageReady && model.webContainer?.webView !== network }
    let sample = model.webContainer!.webView
    let marker = try await sample.evaluateJavaScript("document.querySelector('#sample-inspector').textContent") as? String
    precondition(marker == "Sample inspector", "Load the plugin HTML without assuming a root element")
    let sampleState = try await sample.callAsyncJavaScript(
      "return await window.webkit.messageHandlers.snapoHost.postMessage({command:'hostState'});",
      arguments: [:], in: nil, contentWorld: .page
    ) as? [String: Any]
    precondition(sampleState?["connected"] as? Bool == true)
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
    let activeState = try await network.callAsyncJavaScript(
      "return await window.webkit.messageHandlers.snapoHost.postMessage({command:'hostState'});",
      arguments: [:], in: nil, contentWorld: .page
    ) as? [String: Any]
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
    model.selectApp(second)
    let replacement = model.webContainer!.webView
    precondition(replacement !== network, "Changing the selected app replaces that inspector's view")
    try await eventually("The replacement page should load") { model.isPageReady && replacement.superview != nil }
    let stored = try await replacement.evaluateJavaScript("localStorage.getItem('\(storageKey)')") as? String
    precondition(stored == "network value", "Storage survives replacement pages of the same inspector")
    let isolated = try await tweaks.evaluateJavaScript("localStorage.getItem('\(storageKey)')")
    precondition(isolated is NSNull, "Each inspector has separate storage")
    _ = try await replacement.evaluateJavaScript("localStorage.removeItem('\(storageKey)')")
    precondition(network.superview == nil)
    let replacementState = try await replacement.evaluateJavaScript("typeof window.testState") as? String
    precondition(replacementState == "undefined")
    model.selectInspector(second, option: second.inspectors.first { $0.kind == .tweaks }!)
    precondition(model.webContainer?.webView !== tweaks, "Do not reuse another app's cached Tweaks page")
    try await eventually("The second app's Tweaks page should load") { model.isPageReady }
    print("Changing apps replaces cached pages and preserves inspector storage")

    model.selectApp(first)
    model.selectApp(second)
    model.selectApp(first)
    try await eventually("Rapid selection should load only the final page") {
      model.isPageReady && model.selectedInspectorApp?.id == first.id && model.webContainer?.webView.superview != nil
    }
    let finalPage = model.webContainer!.webView
    model.stop()
    try await eventually("Stopping the host should unmount the active page") { finalPage.superview == nil }
    print("Rapid selection and shutdown leave no obsolete page mounted")
  }
}
