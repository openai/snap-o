import Foundation
import Observation
@testable import Snap_O
import Synchronization
import Testing

@MainActor
struct ToolHostObservationTests {
  @Test
  func toolbarAndConnectionUpdatesDoNotInvalidateMenuState() {
    let page = makePage()
    defer { page.container.stop() }
    let menuChanges = Mutex(0)
    withObservationTracking {
      _ = page.isReady
      _ = page.identity.storageIdentifier
      _ = page.identity.developmentURL
    } onChange: {
      menuChanges.withLock { $0 += 1 }
    }

    for revision in 1 ... 10 {
      page.toolbar = ToolToolbar(revision: revision, actions: [])
      page.connection.revision = revision
      page.error = "Synthetic load failure \(revision)"
    }
    #expect(menuChanges.withLock { $0 } == 0)

    page.isReady = true
    #expect(menuChanges.withLock { $0 } == 1)
  }

  @Test
  func toolbarChangesRemainObservable() {
    let page = makePage()
    defer { page.container.stop() }
    let toolbarChanges = Mutex(0)
    withObservationTracking {
      _ = page.toolbar.actions
    } onChange: {
      toolbarChanges.withLock { $0 += 1 }
    }

    page.isReady = true
    page.connection.connected = true
    #expect(toolbarChanges.withLock { $0 } == 0)

    page.toolbar.actions.append(ToolToolbarAction(
      placement: .start, type: .button, id: "clear", icon: .clear,
      label: "Clear", enabled: true, value: nil, inputRevision: nil
    ))
    #expect(toolbarChanges.withLock { $0 } == 1)
    #expect(page.toolbar.actions.map(\.id) == ["clear"])
  }

  @Test(arguments: [false, true])
  func waitingForAnAppDoesNotCreateAWebView(restoreSelection: Bool) throws {
    let suite = "ToolHostWaitingTests." + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let app = selectionApp()
    if restoreSelection {
      var selection = ToolSelection()
      selection.reconcile([app])
      defaults.set(selection.serialized, forKey: "inspectorPreferences")
    }
    let adb = ADBService()
    let service = ToolService(adbService: adb, deviceTracker: DeviceTracker(adbService: adb))
    let host = ToolHostModel(service: service, preferences: defaults)
    defer { host.stop() }

    #expect(host.preferredPluginID == (restoreSelection ? .network : nil))
    #expect(host.selectedTool == nil)
    #expect(host.presentation != .tool)
    #expect(host.webContainer == nil)
    #expect(!host.isPageReady)

    // A remembered app or toolbar choice does not mean its process is available.
    host.selectTool(app, option: app.tools[0])
    #expect(host.selectedToolApp?.id == app.id)
    #expect(host.selectedTool == nil)
    #expect(host.presentation != .tool)
    #expect(host.webContainer == nil)
  }

  @Test(arguments: [false, true])
  func switchingToAnUnavailableAppRemovesThePreviousPage(reusePID: Bool) async throws {
    let suite = "ToolHostSwitchTests." + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    var first = selectionApp(kinds: [.network], processIdentity: "boot:10:1")
    first.tools[0].compatibility = .unknown
    var next = selectionApp(
      reusePID ? 10 : 20, kinds: [.network],
      process: reusePID ? "com.example.demo" : "com.example.other",
      processIdentity: reusePID ? "boot:10:2" : "boot:20:1"
    )
    next.tools[0].compatibility = .unknown
    var apps = [first]
    let appTool = AppToolModel(preferences: defaults, discover: {
      ToolDiscoverySnapshot(apps: apps)
    }, openApp: { _ in })
    let adb = ADBService()
    let service = ToolService(adbService: adb, deviceTracker: DeviceTracker(adbService: adb))
    let host = ToolHostModel(service: service, preferences: defaults, appTool: appTool)
    defer { host.stop() }
    try await eventually { host.webContainer != nil }
    let previous = try #require(host.webContainer)
    let lateReadiness = previous.pageReadinessChangedHandler
    previous.pageReadinessChangedHandler?(true)
    #expect(host.isPageReady)

    apps = []
    appTool.refresh()
    try await eventually { host.presentation != .tool }
    #expect(host.webContainer === previous, "Keep cached content when the same app disconnects")

    host.selectTool(next, option: next.tools[0])
    #expect(host.selectedTool == nil)
    #expect(host.webContainer == nil)
    #expect(!host.isPageReady)
    #expect(host.toolbarActions.isEmpty)
    #expect(!host.canConfigureDevelopmentServer)
    #expect(host.developmentURL == nil)
    lateReadiness?(true)
    #expect(!host.isPageReady, "Callbacks from the removed page must not restore its readiness")

    apps = [next]
    appTool.refresh()
    try await eventually { host.webContainer != nil }
    #expect(host.webContainer !== previous)
    #expect(host.selectedTool?.appId == next.id)
    #expect(!host.isPageReady)
  }

  @Test
  func appDiscoveryIsNotLoadedUntilTheFirstSuccessfulScan() async throws {
    let suite = "ToolHostDiscoveryTests." + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    var selection = ToolSelection()
    selection.reconcile([selectionApp()])
    defaults.set(selection.serialized, forKey: "inspectorPreferences")
    var scans = 0
    var shouldFail = true
    var apps: [InspectableApp] = []
    let appTool = AppToolModel(preferences: defaults, discover: {
      scans += 1
      if shouldFail { throw NSError(domain: "ToolHostDiscoveryTests", code: 1) }
      return ToolDiscoverySnapshot(apps: apps)
    }, openApp: { _ in })
    let adb = ADBService()
    let service = ToolService(adbService: adb, deviceTracker: DeviceTracker(adbService: adb))
    let host = ToolHostModel(service: service, preferences: defaults, appTool: appTool)
    defer { host.stop() }

    #expect(host.presentation == .findingApps)
    try await eventually { scans == 1 }
    #expect(host.presentation == .discoveryFailed, "A failed scan does not establish that no apps exist")
    #expect(host.webContainer == nil)

    shouldFail = false
    appTool.refresh()
    try await eventually { host.presentation == .noApps }
    #expect(host.toolApps.isEmpty)
    #expect(host.selectedToolApp == nil)

    apps = [selectionApp(20, process: "com.example.other")]
    appTool.refresh()
    try await eventually { !host.toolApps.isEmpty }
    #expect(host.presentation == .needsSelection)
    #expect(host.selectedToolApp == nil, "An unmatched saved preference still needs an explicit selection")
    #expect(host.webContainer == nil)
  }

  @Test
  func cachedUpdatesDoNotCompleteDiscoveryOrClearFailure() async throws {
    let suite = "ToolHostCachedDiscoveryTests." + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let (updates, continuation) = AsyncStream<Void>.makeStream()
    defer { continuation.finish() }
    var reply: CheckedContinuation<ToolDiscoverySnapshot, Error>?
    var reads = 0
    let appTool = AppToolModel(preferences: defaults, discover: {
      try await withCheckedThrowingContinuation { reply = $0 }
    }, changes: {
      continuation.yield(())
      return updates
    }, currentDiscovery: {
      reads += 1
      return ToolDiscoverySnapshot(apps: [], revision: UInt64(reads + 10))
    }, openApp: { _ in })
    let adb = ADBService()
    let service = ToolService(adbService: adb, deviceTracker: DeviceTracker(adbService: adb))
    let host = ToolHostModel(service: service, preferences: defaults, appTool: appTool)
    defer { host.stop() }

    try await eventually { reads == 1 && reply != nil }
    #expect(host.presentation == .findingApps)
    #expect(host.webContainer == nil)
    reply?.resume(throwing: NSError(domain: "DiscoveryTests", code: 1))
    reply = nil
    try await eventually { host.presentation == .discoveryFailed }
    continuation.yield(())
    try await eventually { reads == 2 }
    #expect(host.presentation == .discoveryFailed)

    host.retryDiscovery()
    #expect(host.presentation == .findingApps)
    try await eventually { reply != nil }
    // Finishing a scan establishes the empty state even when its data revision is older.
    reply?.resume(returning: ToolDiscoverySnapshot(apps: [], revision: 1))
    reply = nil
    try await eventually { host.presentation == .noApps }
    #expect(host.webContainer == nil)
  }

  @Test
  func switchingAppsDiscardsHiddenToolPages() async throws {
    let suite = "ToolHostHiddenPageTests." + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    var first = selectionApp()
    for index in first.tools.indices {
      first.tools[index].compatibility = .unknown
    }
    var next = selectionApp(20, process: "com.example.other")
    for index in next.tools.indices {
      next.tools[index].compatibility = .unknown
    }
    let apps = [first, next]
    let appTool = AppToolModel(preferences: defaults, discover: {
      ToolDiscoverySnapshot(apps: apps)
    }, openApp: { _ in })
    let adb = ADBService()
    let service = ToolService(adbService: adb, deviceTracker: DeviceTracker(adbService: adb))
    let host = ToolHostModel(service: service, preferences: defaults, appTool: appTool)
    defer { host.stop() }
    try await eventually { host.webContainer != nil }
    let network = try #require(host.webContainer)
    let lateReadiness = network.pageReadinessChangedHandler
    host.selectTool(first, option: first.tools[1])
    let tweaks = try #require(host.webContainer)
    #expect(tweaks !== network)
    host.selectTool(first, option: first.tools[0])
    #expect(host.webContainer === network, "Switching tools preserves the same app's page")
    host.selectTool(next, option: next.tools[1])
    #expect(host.webContainer !== tweaks)
    lateReadiness?(true)
    #expect(!host.isPageReady)
    host.selectTool(first, option: first.tools[0])
    #expect(host.webContainer !== network, "A hidden page cannot outlive its selected app")
    #expect(!host.isPageReady)
  }

  private func eventually(_ condition: () -> Bool) async throws {
    for _ in 0 ..< 100 {
      if condition() { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(condition())
  }

  private func makePage() -> ToolHostModel.Page {
    ToolHostModel.Page(
      identity: ToolHostModel.PageIdentity(
        appID: nil, server: nil, processIdentity: nil, storageIdentifier: UUID(),
        packageRevision: nil, frontend: nil, developmentURL: nil, compatibility: .unknown
      ),
      container: ToolWebContainer(bridge: ToolWebBridge(), storageIdentifier: nil)
    )
  }
}
