import Clocks
import Dependencies
import DependenciesTestSupport
import Foundation
import Observation
@testable import Snap_O
import Testing

@Suite("Tool selection and discovery", .timeLimit(.minutes(1)), .dependency(\.continuousClock, TestClock()))
@MainActor
struct ToolSelectionTests {
  @Dependency(\.continuousClock, as: TestClock<Duration>.self) private var clock

  @Test
  func modelLifecycle() async throws {
    let suite = "SnapOPluginTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(selected(.tweaks).serialized, forKey: "inspectorPreferences")
    var scans = 0
    var apps = [selectionApp()]
    var failScan = false
    let scanReply = TestValue<CheckedContinuation<[InspectableApp], Error>?>(nil)
    var delayScan = false
    let launchReply = TestValue<CheckedContinuation<Void, Error>?>(nil)
    var launched: [OpenAppInput] = []
    let model = AppToolModel(preferences: defaults, discover: {
      scans += 1
      if delayScan { return try await ToolDiscoverySnapshot(
        apps: withCheckedThrowingContinuation { scanReply.value = $0 }
      ) }
      if failScan { throw TestError.failed }
      return ToolDiscoverySnapshot(apps: apps)
    }, openApp: { input in
      launched.append(input)
      try await withCheckedThrowingContinuation { launchReply.value = $0 }
    })
    let snapshots = TestValue<[AppToolSnapshot]>([])
    model.stateChanged = { snapshots.value.append($0) }
    await model.start()?.value
    #expect(scans == 1 && model.snapshot.discovery == .ready, "Scan immediately and finish loading")
    #expect(model.snapshot.state.selection?.kind == .tweaks, "Hydrate preferences before discovery")
    let firstRevision = model.snapshot.revision
    failScan = true
    await model.refresh()?.value
    #expect(model.snapshot.state.selection?.kind == .tweaks, "A failed scan must not disconnect")
    failScan = false
    delayScan = true
    let slowScan = model.refresh()
    try await waitForState { scanReply.value != nil }
    let slowScanCount = scans
    #expect(model.refresh() == nil, "Do not overlap discovery requests")
    #expect(scans == slowScanCount)
    model.selectTool(selectionApp(), option: selectionApp().tools[0])
    scanReply.value?.resume(returning: apps)
    scanReply.value = nil
    await slowScan?.value
    #expect(model.snapshot.state.selection?.kind == .network, "Honor native selection during a scan")
    #expect(model.snapshot.revision > firstRevision, "Publish increasing revisions")
    delayScan = false

    apps = []
    await model.refresh()?.value
    let launch = try model.openSelectedApp(appId: #require(model.snapshot.state.selectedApp?.id))
    #expect(try model.openSelectedApp(appId: #require(model.snapshot.state.selectedApp?.id)) == nil)
    try await waitForState { launchReply.value != nil }
    #expect(launched.count == 1 && launched[0].androidUserId == 0, "Prevent duplicate app launches")
    #expect(model.snapshot.appLaunch?.pending == true, "Show pending launch")
    await clock.advance(by: .seconds(5))
    #expect(model.snapshot.appLaunch?.pending == true, "Do not allow duplicate launch while ADB is still running")
    launchReply.value?.resume()
    launchReply.value = nil
    await launch?.value
    try await waitForState { snapshots.value.last?.appLaunch?.pending == false }
    #expect(model.snapshot.appLaunch?.pending == false, "Complete after both ADB and the wait window")
    let failedLaunch = try model.openSelectedApp(appId: #require(model.snapshot.state.selectedApp?.id))
    try await waitForState { launchReply.value != nil }
    launchReply.value?.resume(throwing: TestError.failed)
    launchReply.value = nil
    await failedLaunch?.value
    #expect(model.snapshot.appLaunch?.error != nil && model.snapshot.appLaunch?.pending == false, "Publish launch errors")

    let work = selectionApp(20, process: "com.example.demo:worker", user: 10)
    apps = [work]
    await model.refresh()?.value
    model.selectApp(work)
    #expect(model.openSelectedApp(appId: selectionApp().id) == nil, "Ignore an Open click from the previous app")
    let staleLaunch = try model.openSelectedApp(appId: #require(model.snapshot.state.selectedApp?.id))
    try await waitForState { launchReply.value != nil }
    #expect(
      launched.last?.androidUserId == 10 && launched.last?.packageName == "com.example.demo",
      "Launch a secondary process through its package and profile"
    )
    model.selectApp(selectionApp())
    launchReply.value?.resume(throwing: TestError.failed)
    launchReply.value = nil
    await staleLaunch?.value
    #expect(
      model.snapshot.appLaunch?.error == nil && model.snapshot.appLaunch?.pending == false,
      "Ignore a late launch result after switching apps"
    )
    model.selectApp(selectionApp(user: nil))
    #expect(model.snapshot.appLaunch == nil, "Do not launch without a verified profile")

    model.selectApp(work)
    let stoppedLaunch = try model.openSelectedApp(appId: #require(model.snapshot.state.selectedApp?.id))
    try await waitForState { launchReply.value != nil }
    let published = snapshots.value.count
    let stopped = model.stop()
    launchReply.value?.resume()
    launchReply.value = nil
    await stoppedLaunch?.value
    await stopped.value
    #expect(snapshots.value.count == published, "Stop publishing after shutdown")
  }

  @Test
  func hostConnections() async throws {
    let suite = "SnapOPluginTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    var apps = [selectionApp()]
    let model = AppToolModel(preferences: defaults, discover: {
      ToolDiscoverySnapshot(apps: apps)
    }, openApp: { _ in })
    #expect(model.snapshot.pageState(for: .network).isWaiting, "Wait for initial native discovery")
    await model.start()?.value
    var page = model.snapshot.pageState(for: .network)
    #expect(page.isActive && page.isConnected && !page.isWaiting, "Publish the active Network connection")
    let json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(page)) as? [String: Any])
    #expect((json["selection"] as? [String: Any])?["protocolVersion"] == nil, "Keep tool protocols out of host selection")
    #expect(json["state"] == nil && json["apps"] == nil, "Do not send native selection internals to pages")
    #expect(model.snapshot.pageState(for: .tweaks).selection == nil, "Send only this page's connection")
    apps = []
    await model.refresh()?.value
    page = model.snapshot.pageState(for: .network)
    #expect(!page.isConnected, "Disconnect retained data")
    apps = [selectionApp(20)]
    await model.refresh()?.value
    page = model.snapshot.pageState(for: .network)
    #expect(!page.isConnected && page.selection?.server.socketName == "snapo_network_10", "Do not follow replacement discovery")
    model.reconnectToNewProcess()
    page = model.snapshot.pageState(for: .network)
    #expect(page.isConnected && page.selection?.server.socketName == "snapo_network_20", "Connect only after native approval")
    model.selectTool(selectionApp(20), option: selectionApp(20).tools[1])
    page = model.snapshot.pageState(for: .network)
    #expect(!page.isActive && !page.isConnected, "Deactivate the hidden Network page")
    #expect(page.selection?.server.socketName == "snapo_network_20", "Keep the hidden page mounted with its data")
    #expect(model.snapshot.pageState(for: .tweaks).isConnected, "Activate Tweaks from the native choice")

    apps = [selectionApp(30, kinds: [.network])]
    await model.refresh()?.value
    #expect(model.snapshot.state.replacementApp == apps[0])
    model.reconnectToNewProcess()
    #expect(model.snapshot.pageState(for: .network).isConnected, "Reconnect even when the previous tool is absent")
    #expect(model.snapshot.state.selectedApp?.tools.map(\.kind) == [.network])

    await model.stop().value
    try await clock.checkSuspension()
  }

  @Test
  func pushedDiscovery() async throws {
    let suite = "SnapOPluginTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let (updates, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    defer { continuation.finish() }
    var latest = ToolDiscoverySnapshot(apps: [selectionApp()], revision: 2)
    let scanReply = TestValue<CheckedContinuation<ToolDiscoverySnapshot, Never>?>(nil)
    var scans = 0
    let model = AppToolModel(preferences: defaults, discover: {
      scans += 1
      return await withCheckedContinuation { scanReply.value = $0 }
    }, changes: { updates }, currentDiscovery: { latest }, openApp: { _ in })
    let publications = TestValue(0)
    model.stateChanged = { _ in publications.value += 1 }
    let scan = model.start()
    try await waitForState { scanReply.value != nil }
    continuation.yield(())
    try await waitForState { publications.value == 1 }
    #expect(
      model.snapshot.state.selectedApp?.metadata == selectionApp().metadata,
      "Publish completed metadata before the polling scan returns"
    )
    #expect(scans == 1, "A discovery update does not start another device scan")
    scanReply.value?.resume(returning: ToolDiscoverySnapshot(apps: [selectionApp(20)], revision: 1))
    await scan?.value
    #expect(model.snapshot.state.selectedApp?.id == selectionApp().id, "An older scan cannot overwrite a newer discovery update")
    latest = ToolDiscoverySnapshot(apps: [selectionApp(connectedKinds: [])], revision: 3)
    let previousPublications = publications.value
    continuation.yield(())
    try await waitForState { publications.value > previousPublications }
    #expect(model.snapshot.state.selection == nil, "Publish a failed health check without another poll")
    #expect(model.snapshot.state.selectedApp?.metadata == selectionApp().metadata, "Keep metadata when the health check disconnects")
    #expect(scans == 1, "Health updates do not start another device scan")
    let stopped = model.stop()
    let stoppedRevision = model.snapshot.revision
    latest = ToolDiscoverySnapshot(apps: [selectionApp()], revision: 4)
    continuation.yield(())
    await stopped.value
    #expect(model.snapshot.revision == stoppedRevision, "Stop consuming discovery updates after shutdown")
  }

  @Test
  func canceledDiscoveryRestart() async throws {
    let suite = "SnapOPluginTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let replies = TestValue<[CheckedContinuation<ToolDiscoverySnapshot, Never>]>([])
    let model = AppToolModel(preferences: defaults, discover: {
      await withCheckedContinuation { replies.value.append($0) }
    }, openApp: { _ in })
    let canceled = model.start()
    try await waitForState { replies.value.count == 1 }
    model.stop()
    let restarted = model.start()
    try await waitForState { replies.value.count == 2 }
    replies.value[0].resume(returning: ToolDiscoverySnapshot(apps: [selectionApp()]))
    await canceled?.value
    #expect(model.snapshot.discovery == .searching, "Ignore the canceled scan's result")
    #expect(model.refresh() == nil, "The canceled scan must not clear the new scan")
    #expect(replies.value.count == 2)
    replies.value[1].resume(returning: ToolDiscoverySnapshot(apps: [selectionApp(20)]))
    await restarted?.value
    #expect(model.snapshot.state.selectedApp?.id == selectionApp(20).id, "Publish only the restarted scan")
    await model.stop().value
    try await clock.checkSuspension()
  }
}

private enum TestError: Error { case failed }
