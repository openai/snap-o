import Foundation
import SnapODeviceClient
import SwiftUI
import WebKit

actor NetworkInspectorService {
  let apps: [InspectableApp]
  private let output = AsyncStream<NetworkInspectorOutput>.makeStream()
  private(set) var streamStarts = 0
  private(set) var cancelledStarts = 0
  private(set) var stoppedKinds: [AppInspectorKind] = []
  private var holdCleanup = false
  private var cleanup: CheckedContinuation<Void, Never>?

  var isCleanupBlocked: Bool {
    cleanup != nil
  }

  func holdNextCleanup() {
    holdCleanup = true
  }

  func releaseCleanup() {
    cleanup?.resume()
    cleanup = nil
  }

  init(apps: [InspectableApp]) {
    self.apps = apps
  }

  func discoverInspectors() async -> InspectorDiscoverySnapshot {
    InspectorDiscoverySnapshot(apps: apps, networkServers: [])
  }

  func outputStream() -> AsyncStream<NetworkInspectorOutput> {
    output.stream
  }

  func isRunning() -> Bool {
    true
  }

  func openApp(_ input: OpenAppInput) async throws {}
  func listTweaks(for reference: InspectorServerReference) async throws -> TweakList {
    TweakList(tweaks: [])
  }

  func updateTweaks(_ input: UpdateTweaksInput) async throws -> TweakUpdates {
    TweakUpdates(tweaks: [], errors: nil)
  }

  func invokeTweakAction(_ input: InvokeTweakActionInput) async throws {}
  func startTweakStream(_ reference: InspectorServerReference) async throws -> NetworkStreamStarted {
    NetworkStreamStarted(streamId: "tweaks")
  }

  func stopTweakStream(_ id: String) async {}
  func startStream(_ reference: NetworkServerReference) async throws -> NetworkStreamStarted {
    streamStarts += 1
    do { try await Task.sleep(for: .seconds(30)) } catch {
      cancelledStarts += 1
      throw error
    }
    return NetworkStreamStarted(streamId: "network")
  }

  func stopStream(_ id: String) async {}
  func stopAllStreams(kind: AppInspectorKind) async {
    stoppedKinds.append(kind)
    if holdCleanup {
      holdCleanup = false
      await withCheckedContinuation { cleanup = $0 }
    }
  }

  func loadBodies(_ input: NetworkLoadBodiesInput) async -> NetworkRequestBodies {
    NetworkRequestBodies(
      requestId: input.requestId, requestBody: nil, responseBody: nil,
      responseBodyBase64Encoded: nil, responseBodyLoadError: nil
    )
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
    _ = try await network.evaluateJavaScript("window.testState = 'network state'")
    let stoppedBeforeTweaks = await service.stoppedKinds
    precondition(!stoppedBeforeTweaks.contains(.tweaks), "Do not create inactive inspector pages eagerly")

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
      "return await window.webkit.messageHandlers.snapoNetwork.postMessage({command:'inspectorHostState'});",
      arguments: [:], in: nil, contentWorld: .page
    ) as? [String: Any]
    precondition(hiddenNetworkState?["isActive"] as? Bool == false)
    print("Inspector types reuse their own view and receive inactive connection state")

    model.selectInspector(first, option: first.inspectors.first { $0.kind == .network }!)
    try await eventually("Network should remount") { network.superview != nil }
    _ = try await network.evaluateJavaScript("""
    void window.webkit.messageHandlers.snapoNetwork.postMessage({
      command: 'startStream', payload: {deviceId:'phone',socketName:'snapo_network_10'}
    }).catch(() => {});
    """)
    try await eventually("Old page request should start") { await service.streamStarts == 1 }
    await service.holdNextCleanup()
    model.webContainer!.recoverFromEventOverflow()
    try await eventually("Page recovery should begin cleanup") { await service.isCleanupBlocked }
    model.selectApp(second)
    let replacement = model.webContainer!.webView
    precondition(replacement !== network, "Changing the selected app replaces that inspector's view")
    try await Task.sleep(for: .milliseconds(50))
    precondition(!model.isPageReady, "Wait for old recovery cleanup before starting the replacement")
    await service.releaseCleanup()
    try await eventually("Cancel old requests before loading the replacement") {
      await service.cancelledStarts == 1 && model.isPageReady && replacement.superview != nil
    }
    precondition(network.superview == nil)
    let replacementState = try await replacement.evaluateJavaScript("typeof window.testState") as? String
    precondition(replacementState == "undefined")
    model.selectInspector(second, option: second.inspectors.first { $0.kind == .tweaks }!)
    precondition(model.webContainer?.webView !== tweaks, "Do not reuse another app's cached Tweaks page")
    try await eventually("The second app's Tweaks page should load") { model.isPageReady }
    print("Changing apps replaces cached pages and cancels pending bridge requests")

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
