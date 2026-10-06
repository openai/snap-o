import Foundation
import Observation

@main
@MainActor
struct DeviceInventoryTests {
  static func main() async {
    DeviceManagerTests.run()
    let tests: [(String, (Fixture) async -> Void)] = [
      ("local inventory does not wait for ADB", localInventoryDoesNotWaitForADB),
      ("preview does not wait for identity", previewDoesNotWaitForIdentity),
      ("matching preserves one row", matchingPreservesOneRow),
      ("boot status updates after identity", bootStatusUpdatesAfterIdentity),
      ("refresh reuses identity", refreshReusesIdentity),
      ("renaming publishes new device snapshots", renamingPublishesNewSnapshots),
      ("failed matching leaves device accessible", failedMatchingLeavesDeviceAccessible),
      ("reused transport discards old properties", reusedTransportDiscardsOldProperties),
      ("stale matching cannot restore old transport", staleMatchingCannotRestoreOldTransport),
      ("disconnect removes current devices", disconnectRemovesCurrentDevices),
      ("screenshots retain their connection", screenshotsRetainTheirConnection),
      ("screenshots reject unknown devices", screenshotsRejectUnknownDevices),
      ("readiness distinguishes pending and empty discovery", readinessWaitsForDiscovery),
      ("readiness returns current devices", readinessReturnsCurrentDevices),
      ("readiness cancellation preserves other waiters", readinessCancellationPreservesOtherWaiters),
      ("shutdown wakes readiness waiters", shutdownWakesReadinessWaiters),
      ("shutdown joins pending work", shutdownJoinsPendingWork),
      ("shutdown rejects deferred actions", shutdownRejectsDeferredActions)
    ]
    for (name, test) in CommandLine.arguments.contains("--reverse") ? tests.reversed() : tests {
      let fixture = Fixture()
      await fixture.start()
      await test(fixture)
      await fixture.stop()
      print("Passed: \(name)")
    }
  }

  static func localInventoryDoesNotWaitForADB(_ fixture: Fixture) async {
    precondition(fixture.manager.entries.count == 1)
    precondition(fixture.adb.client.bootRequests == 0)
    precondition(fixture.manager.inventory.connected == nil && fixture.manager.inventory.ready == nil)
  }

  static func previewDoesNotWaitForIdentity(_ fixture: Fixture) async {
    await fixture.tracker.update([device()])
    await waitForState { fixture.client.identityRequests == 1 && fixture.updates.last?.count == 1 }
    precondition(fixture.updates.last?.first?.displayTitle == "Generic model")
    precondition(fixture.manager.latestDevices.isEmpty, "Preview readiness must not authorize shell-dependent captures")
    precondition(fixture.manager.inventory.ready == nil, "Preview discovery must not mark capture discovery as loaded")
  }

  static func matchingPreservesOneRow(_ fixture: Fixture) async {
    let rowID = fixture.manager.entries[0].id
    await fixture.tracker.update([device()])
    await waitForState { fixture.client.identityRequests == 1 }
    precondition(fixture.manager.entries.count == 1)
    precondition(fixture.manager.entries[0].id == rowID)
    precondition(fixture.manager.entries[0].detail == nil, "Pending matching must not display a lock warning")
    await fixture.client.identityGate.open()
    await waitForState { fixture.manager.connectedDevices.first?.displayTitle == "Test Tablet" }
    precondition(fixture.manager.entries.count == 1 && fixture.manager.entries[0].id == rowID)
    precondition(fixture.adb.client.bootRequests == 0, "Matching must not wait for the blocked ADB refresh")
  }

  static func bootStatusUpdatesAfterIdentity(_ fixture: Fixture) async {
    await fixture.connect()
    await fixture.adb.client.connectionsGate.open()
    await waitForState { !fixture.manager.isRefreshing }
    let refresh = Task { await fixture.manager.refresh() }
    await waitForState { fixture.adb.client.bootRequests > 0 }
    precondition(fixture.manager.emulators[0].state == .starting)
    await fixture.adb.client.bootGate.open()
    await refresh.value
    precondition(fixture.manager.emulators[0].state == .running)
  }

  static func refreshReusesIdentity(_ fixture: Fixture) async {
    await fixture.connect()
    await fixture.allowRefresh()
    let requests = fixture.client.identityRequests
    fixture.client.resolvesSerial = false
    await fixture.manager.refresh()
    precondition(fixture.client.identityRequests == requests)
    precondition(fixture.manager.connectedDevices[0].displayTitle == "Test Tablet")
  }

  static func renamingPublishesNewSnapshots(_ fixture: Fixture) async {
    await fixture.connect(ready: true)
    await fixture.allowRefresh()
    let captured = fixture.manager.latestDevices[0]
    fixture.client.title = "Renamed Tablet"
    await fixture.manager.refresh()
    await waitForState { fixture.updates.last?.first?.displayTitle == "Renamed Tablet" }
    precondition(fixture.manager.latestDevices[0].displayTitle == "Renamed Tablet")
    precondition(captured.displayTitle == "Test Tablet", "Existing capture snapshots must retain their name")
    precondition(fixture.manager.latestDevices[0].avdName == "Test Tablet", "Renaming must preserve AVD identity")
  }

  static func failedMatchingLeavesDeviceAccessible(_ fixture: Fixture) async {
    fixture.client.resolvesSerial = false
    await fixture.client.identityGate.open()
    await fixture.tracker.update([device()])
    await waitForState { fixture.client.identityRequests == 1 && fixture.manager.matchingSerials.isEmpty }
    precondition(fixture.manager.entries.contains { $0.serial == "emulator-5554" })
  }

  static func reusedTransportDiscardsOldProperties(_ fixture: Fixture) async {
    await fixture.connect(ready: true)
    fixture.client.identityGate = TestGate()
    await fixture.tracker.update([device(transportID: "2")])
    await waitForState { fixture.manager.connectedDevices.first?.transportID == "2" }
    precondition(fixture.manager.connectedDevices[0].displayTitle == "Generic model")
    precondition(fixture.manager.latestDevices.isEmpty)
  }

  static func staleMatchingCannotRestoreOldTransport(_ fixture: Fixture) async {
    await fixture.tracker.update([device(transportID: "3")])
    await waitForState { fixture.client.identityRequests == 1 }
    await fixture.tracker.update([device(transportID: "4")])
    await waitForState { fixture.client.identityRequests == 2 }
    await fixture.client.identityGate.open()
    await waitForState { fixture.manager.matchingSerials.isEmpty && fixture.manager.connectedDevices.first?.displayName != nil }
    precondition(fixture.manager.connectedDevices[0].transportID == "4")
    precondition(fixture.manager.entries.count == 1)
  }

  static func disconnectRemovesCurrentDevices(_ fixture: Fixture) async {
    await fixture.connect(ready: true)
    await fixture.tracker.update([], ready: true)
    await waitForState { fixture.manager.connectedDevices.isEmpty && fixture.manager.latestDevices.isEmpty }
  }

  static func screenshotsRetainTheirConnection(_ fixture: Fixture) async {
    await fixture.connect()
    guard let original = fixture.manager.connectedDevices.first?.connection else {
      preconditionFailure("Expected connected target")
    }
    let gate = TestGate()
    fixture.adb.client.screenshotGate = gate
    let oldRequest = Task { () -> Bool in
      do {
        _ = try await fixture.manager.screenshot(for: original)
        return false
      } catch { return true }
    }
    await waitForState { fixture.adb.client.screenshotTargets.count == 1 }
    original.invalidate()
    await fixture.tracker.update([device(transportID: "2")])
    await waitForState { fixture.manager.connectedDevices.first?.connection != original }
    guard let replacement = fixture.manager.connectedDevices.first?.connection else {
      preconditionFailure("Expected replacement target")
    }
    let newRequest = Task { try await fixture.manager.screenshot(for: replacement) }
    await waitForState { fixture.adb.client.screenshotTargets.count == 2 }
    precondition(fixture.adb.client.screenshotTargets == [original, replacement])
    await gate.open()
    let rejected = await oldRequest.value
    precondition(rejected, "An old screenshot cannot move to the replacement device")
    do {
      let data = try await newRequest.value
      precondition(data == Data([1, 2, 3]))
    } catch { preconditionFailure("The replacement should support a new screenshot: \(error)") }
  }

  static func screenshotsRejectUnknownDevices(_ fixture: Fixture) async {
    do {
      _ = try await fixture.manager.screenshot(for: DeviceTarget(serial: "missing", transportID: "1"))
      preconditionFailure("Unknown devices must not open an unbound ADB request")
    } catch {}
    precondition(fixture.adb.client.screenshotTargets.isEmpty)
  }

  static func readinessWaitsForDiscovery(_ fixture: Fixture) async {
    let finished = TestValue(false)
    let waiting = await startTestTask {
      let devices = await fixture.manager.waitForReadyDevices()
      finished.value = true
      return devices
    }
    await fixture.tracker.update([device()])
    await waitForState { !fixture.manager.connectedDevices.isEmpty }
    precondition(!finished.value, "Connected devices do not imply ready discovery")
    await fixture.tracker.update([], ready: true)
    let devices = await waiting.value
    precondition(devices == [], "A discovered empty list must finish the wait")
    let current = await fixture.manager.waitForReadyDevices()
    precondition(current == [], "The current empty result must be returned immediately")
  }

  static func readinessReturnsCurrentDevices(_ fixture: Fixture) async {
    await fixture.connect(ready: true)
    let devices = await fixture.manager.waitForReadyDevices()
    precondition(devices == fixture.manager.inventory.ready && devices?.count == 1)
    let cancelled = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return await fixture.manager.waitForReadyDevices()
    }
    let result = await cancelled.value
    precondition(result == nil, "Cancellation must win over a cached ready result")
  }

  static func readinessCancellationPreservesOtherWaiters(_ fixture: Fixture) async {
    let cancelled = await startTestTask { await fixture.manager.waitForReadyDevices() }
    let otherFinished = TestValue(false)
    let other = await startTestTask {
      let result = await fixture.manager.waitForReadyDevices()
      otherFinished.value = true
      return result
    }
    cancelled.cancel()
    let cancelledResult = await cancelled.value
    precondition(cancelledResult == nil && !otherFinished.value)
    await fixture.tracker.update([], ready: true)
    let result = await other.value
    precondition(result == [], "One cancelled waiter must not stop another")
  }

  static func shutdownWakesReadinessWaiters(_ fixture: Fixture) async {
    let first = await startTestTask { await fixture.manager.waitForReadyDevices() }
    let second = await startTestTask { await fixture.manager.waitForReadyDevices() }
    let cleanup = fixture.manager.shutdown()
    let firstResult = await first.value
    let secondResult = await second.value
    precondition(firstResult == nil && secondResult == nil)
    precondition(fixture.manager.isShuttingDown, "Shutdown must wake waiters before cleanup finishes")
    let later = await fixture.manager.waitForReadyDevices()
    precondition(later == nil, "Readiness must remain closed after shutdown begins")
    await fixture.adb.client.connectionsGate.open()
    await cleanup.value
  }

  static func shutdownJoinsPendingWork(_ fixture: Fixture) async {
    await fixture.tracker.update([device(transportID: "3")])
    await waitForState { fixture.client.identityRequests == 1 }
    await fixture.tracker.update([device(transportID: "4")])
    await waitForState { fixture.client.identityRequests == 2 }
    let cleanup = fixture.manager.shutdown()
    let finished = TestValue(false)
    let first = await startTestTask {
      await cleanup.value
      finished.value = true
    }
    let repeated = fixture.manager.shutdown()
    let repeatedFinished = TestValue(false)
    let second = await startTestTask {
      await repeated.value
      repeatedFinished.value = true
    }
    precondition(!finished.value && !repeatedFinished.value)
    precondition(fixture.client.closeCount == 1)
    let requests = fixture.adb.client.connectionRequests
    fixture.manager.start()
    await fixture.manager.refresh()
    let deviceUpdate = await fixture.manager.waitForReadyDevices()
    precondition(deviceUpdate == nil && fixture.adb.client.connectionRequests == requests)
    let devices = fixture.manager.connectedDevices
    await fixture.client.identityGate.open()
    await fixture.adb.client.connectionsGate.open()
    await fixture.adb.client.bootGate.open()
    await first.value
    await second.value
    precondition(fixture.manager.connectedDevices == devices, "Late matching cannot publish after shutdown")
    precondition(!fixture.manager.isRefreshing)
  }

  static func shutdownRejectsDeferredActions(_ fixture: Fixture) async {
    fixture.manager.start(fixture.manager.emulators[0])
    await waitForState { fixture.adb.client.connectionRequests == 2 }
    let cleanup = fixture.manager.shutdown()
    await fixture.adb.client.connectionsGate.open()
    await fixture.client.identityGate.open()
    await fixture.adb.client.bootGate.open()
    await cleanup.value
    precondition(fixture.client.actionRequests.isEmpty, "Cancelled discovery cannot start an emulator after shutdown")
    fixture.manager.start(fixture.manager.emulators[0])
    await fixture.manager.refresh()
    precondition(fixture.client.actionRequests.isEmpty && fixture.adb.client.connectionRequests == 2)
  }

  static func device(avdName: String? = nil, transportID: String = "1") -> Device {
    Device(
      id: "emulator-5554", model: "Generic model", androidVersion: "", vendorModel: nil,
      manufacturer: nil, avdName: avdName, transportID: transportID,
      connection: DeviceTarget(serial: "emulator-5554", transportID: transportID)
    )
  }

  static func waitForState(line: UInt = #line, _ condition: () -> Bool) async {
    while true {
      let (stream, continuation) = AsyncStream<Void>.makeStream()
      let satisfied = withObservationTracking { condition() } onChange: { continuation.yield(()) }
      if satisfied { continuation.finish()
        return
      }
      var iterator = stream.makeAsyncIterator()
      _ = await iterator.next()
      continuation.finish()
      precondition(!Task.isCancelled, "Inventory wait cancelled at line \(line)")
    }
  }

  @MainActor
  @Observable
  final class Fixture {
    let adb = ADBService()
    let tracker = DeviceTracker()
    let client = AndroidHostClient()
    let manager: DeviceManager
    var updates: [[Device]] = []
    private var observer: Task<Void, Never>?

    init() {
      manager = DeviceManager(adb: adb, deviceTracker: tracker, client: client)
    }

    func start() async {
      manager.start()
      observer = Task {
        for await (isShuttingDown, devices) in Observations({ (self.manager.isShuttingDown, self.manager.inventory.connected) }) {
          guard !Task.isCancelled, !isShuttingDown else { return }
          if let devices { updates.append(devices) }
        }
      }
      await waitForState { self.manager.hasLoaded && self.adb.client.connectionRequests > 0 }
    }

    func connect(ready: Bool = false) async {
      await client.identityGate.open()
      await tracker.update([device(avdName: ready ? "Test Tablet" : nil)], ready: ready)
      await waitForState {
        self.manager.connectedDevices.first?.displayName == "Test Tablet"
          && self.manager.matchingSerials.isEmpty
          && (!ready || self.manager.latestDevices.count == 1)
      }
    }

    func allowRefresh() async {
      await adb.client.connectionsGate.open()
      await adb.client.bootGate.open()
      await waitForState { !self.manager.isRefreshing }
    }

    func stop() async {
      let cleanup = manager.shutdown()
      observer?.cancel()
      await client.identityGate.open()
      await adb.client.connectionsGate.open()
      await adb.client.bootGate.open()
      await observer?.value
      await cleanup.value
      precondition(!manager.isRefreshing)
    }
  }
}
