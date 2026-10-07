import Clocks
import Dependencies
import DependenciesTestSupport
import Foundation
import Testing

@Suite("Tool server selection", .dependency(\.continuousClock, TestClock()))
@MainActor
struct ToolServerSelectionTests {
  private let serverID = ADBServerID.remote(UUID())

  @Test
  func removingSelectedServerClearsSelectionAndPreferences() {
    let app = remoteApp()
    let local = selectionApp()
    var selection = ToolSelection()
    selection.reconcile([app, local], serverIDs: [.local, serverID])
    selection.selectTool(app, option: app.tools[1])

    selection.reconcile([app, local], serverIDs: [.local])

    #expect(selection.state.selectedApp == nil)
    #expect(selection.state.selection == nil)
    #expect(selection.state.displayed.isEmpty)
    #expect(selection.state.preferredKind == nil)
    #expect(selection.state.apps == [local])
    #expect(selection.serialized?.contains(app.deviceId) == false)
    selection.reconcile([local], serverIDs: [.local])
    #expect(selection.state.selectedApp == nil, "Do not select another app after removal")
  }

  @Test
  func removingAnotherServerPreservesSelection() {
    let app = remoteApp()
    let otherServer = ADBServerID.remote(UUID())
    var selection = ToolSelection()
    selection.reconcile([app], serverIDs: [.local, serverID, otherServer])
    selection.selectTool(app, option: app.tools[1])
    let previous = selection.state

    selection.reconcile([app], serverIDs: [.local, serverID])

    #expect(selection.state == previous)
  }

  @Test
  func temporaryDisconnectPreservesSelectionAndReconnects() {
    let app = remoteApp()
    var selection = ToolSelection()
    selection.reconcile([app], serverIDs: [.local, serverID])
    selection.selectTool(app, option: app.tools[1])
    let previous = selection.state

    selection.reconcile([], serverIDs: [.local, serverID])
    #expect(selection.state.selection == nil)
    #expect(selection.state.selectedApp == previous.selectedApp)
    #expect(selection.state.displayed == previous.displayed)
    selection.reconcile([app], serverIDs: [.local, serverID])
    #expect(selection.state == previous)
  }

  @Test
  func readdedServerRequiresNewSelection() {
    let app = remoteApp()
    let replacementID = ADBServerID.remote(UUID())
    let replacement = selectionApp(device: DeviceID(serverID: replacementID, serial: "phone").storedValue)
    var selection = ToolSelection()
    selection.reconcile([app], serverIDs: [.local, serverID])
    selection.reconcile([], serverIDs: [.local])

    selection.reconcile([app, replacement], serverIDs: [.local, replacementID])

    #expect(selection.state.apps == [replacement])
    #expect(selection.state.selectedApp == nil)
    selection.selectApp(replacement)
    #expect(selection.state.selection?.appId == replacement.id)
  }

  @Test
  func removedSavedServerDoesNotBlockStartupPicker() {
    let app = remoteApp()
    var original = ToolSelection()
    original.reconcile([app], serverIDs: [.local, serverID])
    var restored = ToolSelection(saved: original.serialized)

    restored.reconcile([app, selectionApp()], serverIDs: [.local])

    #expect(restored.state.selectedApp == nil)
    #expect(restored.state.preferredKind == nil)
    #expect(restored.serialized?.contains(app.deviceId) == false)
  }

  @Test
  func removingServerClearsPendingAppIdentity() {
    let app = selectionApp(process: nil, device: remoteApp().deviceId)
    var selection = ToolSelection()
    selection.reconcile([app], serverIDs: [.local, serverID])
    selection.selectApp(app)
    #expect(selection.state.selectedApp != nil)

    selection.reconcile([app], serverIDs: [.local])

    #expect(selection.state.selectedApp == nil)
    #expect(!selection.state.isRestoring)
  }

  @Test
  func configurationChangesClearModelWhileDiscoveryIsPending() async throws {
    let suite = "ToolServerSelectionTests.\(UUID().uuidString)"
    let preferences = try #require(UserDefaults(suiteName: suite))
    defer { preferences.removePersistentDomain(forName: suite) }
    let app = remoteApp()
    let serverIDs = TestValue<Set<ADBServerID>>([.local, serverID])
    let scanReply = TestValue<CheckedContinuation<ToolDiscoverySnapshot, Never>?>(nil)
    let latest = TestValue<AppToolSnapshot?>(nil)
    var delayScan = false
    let model = AppToolModel(preferences: preferences, configuredServerIDs: { serverIDs.value }, discover: {
      if delayScan {
        return await withCheckedContinuation { scanReply.value = $0 }
      }
      return ToolDiscoverySnapshot(apps: [app])
    }, openApp: { _ in throw TestError.failed })
    model.stateChanged = { latest.value = $0 }
    await model.start()?.value
    #expect(model.snapshot.state.selection?.appId == app.id)
    await model.openSelectedApp(appId: app.id)?.value
    #expect(model.snapshot.appLaunch?.error != nil)
    delayScan = true
    let scan = model.refresh()
    try await waitForState { scanReply.value != nil }

    serverIDs.value = [.local]
    try await waitForState { latest.value?.state.selectedApp == nil }
    #expect(model.snapshot.state.apps.isEmpty)
    #expect(model.snapshot.appLaunch == nil)
    #expect(model.snapshot.presentation == .noApps)
    #expect(preferences.string(forKey: "inspectorPreferences")?.contains(app.deviceId) == false)

    scanReply.value?.resume(returning: ToolDiscoverySnapshot(apps: [app]))
    await scan?.value
    model.selectApp(app)
    model.selectTool(app, option: app.tools[0])
    #expect(model.snapshot.state.selectedApp == nil, "Ignore late discovery and stale picker actions")
    #expect(model.snapshot.state.apps.isEmpty)
    await model.stop().value
  }

  @Test
  func firstPublicationContainsPushedDiscovery() async throws {
    let suite = "ToolServerSelectionTests.\(UUID().uuidString)"
    let preferences = try #require(UserDefaults(suiteName: suite))
    defer { preferences.removePersistentDomain(forName: suite) }
    let (updates, updateContinuation) = AsyncStream<Void>.makeStream()
    let (snapshots, snapshotContinuation) = AsyncStream<AppToolSnapshot>.makeStream()
    defer {
      updateContinuation.finish()
      snapshotContinuation.finish()
    }
    var publications = snapshots.makeAsyncIterator()
    let scanReply = TestValue<CheckedContinuation<ToolDiscoverySnapshot, Never>?>(nil)
    let app = selectionApp()
    let model = AppToolModel(preferences: preferences, discover: {
      await withCheckedContinuation { scanReply.value = $0 }
    }, changes: { updates }, currentDiscovery: {
      ToolDiscoverySnapshot(apps: [app], revision: 2)
    }, openApp: { _ in })
    model.stateChanged = { snapshotContinuation.yield($0) }
    let scan = model.start()
    try await waitForState { scanReply.value != nil }

    updateContinuation.yield(())
    let first = try #require(await publications.next())
    #expect(first.state.selectedApp?.metadata == app.metadata)
    #expect(first.discovery == .searching)

    scanReply.value?.resume(returning: ToolDiscoverySnapshot(apps: [], revision: 1))
    await scan?.value
    #expect(model.snapshot.state.selectedApp?.id == app.id)
    await model.stop().value
  }

  @Test
  func serverObservationPreservesDiscoveryPublicationOrder() async throws {
    let suite = "ToolServerSelectionTests.\(UUID().uuidString)"
    let preferences = try #require(UserDefaults(suiteName: suite))
    defer { preferences.removePersistentDomain(forName: suite) }
    let (updates, updateContinuation) = AsyncStream<Void>.makeStream()
    let (scans, scanContinuation) = AsyncStream<CheckedContinuation<ToolDiscoverySnapshot, Error>>.makeStream()
    let (snapshots, snapshotContinuation) = AsyncStream<AppToolSnapshot>.makeStream()
    defer {
      updateContinuation.finish()
      scanContinuation.finish()
      snapshotContinuation.finish()
    }
    var requests = scans.makeAsyncIterator()
    var publications = snapshots.makeAsyncIterator()
    var reads = 0
    let model = AppToolModel(preferences: preferences, discover: {
      try await withCheckedThrowingContinuation { scanContinuation.yield($0) }
    }, changes: {
      updateContinuation.yield(())
      return updates
    }, currentDiscovery: {
      reads += 1
      return ToolDiscoverySnapshot(apps: [], revision: UInt64(reads + 10))
    }, openApp: { _ in })
    model.stateChanged = { snapshotContinuation.yield($0) }
    let firstScan = model.start()
    let firstReply = try #require(await requests.next())
    #expect(await publications.next()?.presentation == .findingApps)

    firstReply.resume(throwing: TestError.failed)
    await firstScan?.value
    #expect(await publications.next()?.presentation == .discoveryFailed)
    updateContinuation.yield(())
    #expect(await publications.next()?.presentation == .discoveryFailed)

    let retry = model.refresh()
    #expect(await publications.next()?.presentation == .findingApps)
    let secondReply = try #require(await requests.next())
    secondReply.resume(returning: ToolDiscoverySnapshot(apps: [], revision: 1))
    await retry?.value
    #expect(await publications.next()?.presentation == .noApps)
    await model.stop().value
  }

  private func remoteApp() -> InspectableApp {
    selectionApp(device: DeviceID(serverID: serverID, serial: "phone").storedValue)
  }

  private enum TestError: Error {
    case failed
  }
}
