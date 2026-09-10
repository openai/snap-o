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

actor NetworkInspectorService {
  let apps: [InspectableApp]
  let endpoint = InspectorHTTPService.Endpoint(id: UUID(), baseURL: URL(string: "http://127.0.0.1:1234/")!)
  init(apps: [InspectableApp]) {
    self.apps = apps
  }

  func discoverInspectors() async -> InspectorDiscoverySnapshot {
    InspectorDiscoverySnapshot(apps: apps, networkServers: apps.map { app in
      let reference = app.inspectors.first { $0.kind == .network }!.server
      return NetworkInspectorServer(
        server: reference.key, deviceId: app.deviceId, socketName: reference.socketName,
        deviceDisplayTitle: app.deviceDisplayTitle, displayName: app.name,
        isConnected: true, hasAppInfo: true, pid: 10, protocolVersion: 2,
        isProtocolNewerThanSupported: false, isProtocolOlderThanSupported: false, appIconBase64: nil,
        packageName: app.packageName, appName: app.name, instanceId: nil
      )
    })
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

  static func app(_ pid: Int) -> InspectableApp {
    InspectableApp(
      id: "phone:pid:\(pid)", name: "Demo \(pid)", packageName: "com.example.demo\(pid)",
      processName: "com.example.demo\(pid)", androidUserId: 0, deviceId: "phone", deviceDisplayTitle: "Phone",
      appIconBase64: nil, inspectors: AppInspectorKind.allCases.map { kind in
        AppInspectorOption(kind: kind, server: InspectorServerReference(
          deviceId: "phone", socketName: "snapo_\(kind.rawValue)_\(pid)"
        ), protocolVersion: 4)
      }
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
    let service = NetworkInspectorService(apps: [first, second])
    let model = NetworkInspectorHostModel(service: service, preferences: preferences)
    let hosting = NSHostingView(rootView: NetworkInspectorWebView(model: model))
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
    let canCreateSession = try await network.evaluateJavaScript("isSecureContext && typeof crypto.randomUUID === 'function'") as? Bool
    precondition(canCreateSession == true, "The frontend needs a secure localhost origin for session IDs")
    _ = try await network.evaluateJavaScript("window.testState = 'network state'")
    let storageKey = "test-" + UUID().uuidString
    _ = try await network.evaluateJavaScript("localStorage.setItem('\(storageKey)', 'network value')")

    model.selectInspector(first, option: first.inspectors.first { $0.kind == .tweaks }!)
    try await eventually("Tweaks should load in its own view") {
      model.isPageReady && model.webContainer?.webView !== network && network.superview == nil
    }
    let tweaks = model.webContainer!.webView
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
      "return await window.webkit.messageHandlers.snapoNetwork.postMessage({command:'hostState'});",
      arguments: [:], in: nil, contentWorld: .page
    ) as? [String: Any]
    precondition(hiddenNetworkState?["connected"] as? Bool == false)
    print("Inspector types reuse their own view and receive inactive connection state")

    model.selectInspector(first, option: first.inspectors.first { $0.kind == .network }!)
    try await eventually("Network should remount") { network.superview != nil }
    let activeState = try await network.callAsyncJavaScript(
      "return await window.webkit.messageHandlers.snapoNetwork.postMessage({command:'hostState'});",
      arguments: [:], in: nil, contentWorld: .page
    ) as? [String: Any]
    precondition(activeState?["baseURL"] as? String == "http://127.0.0.1:1234/")
    _ = try await network.callAsyncJavaScript(
      """
      return await window.webkit.messageHandlers.snapoNetwork.postMessage({command:'setToolbar',payload:{revision:1,
        actions:[{type:'button',id:'clear',label:'Clear',icon:'clear',enabled:true}]}});
      """, arguments: [:], in: nil, contentWorld: .page
    )
    precondition(model.toolbarActions.count == 1)
    model.webContainer!.recoverFromEventOverflow()
    try await eventually("Page recovery should reload the inspector") { model.isPageReady }
    precondition(model.toolbarActions.isEmpty)
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
