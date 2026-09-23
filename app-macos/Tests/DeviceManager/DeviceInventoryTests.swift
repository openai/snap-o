import Foundation

@main
@MainActor
struct DeviceInventoryTests {
  static func main() async {
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
      ("disconnect removes current devices", disconnectRemovesCurrentDevices)
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
  }

  static func previewDoesNotWaitForIdentity(_ fixture: Fixture) async {
    fixture.tracker.update([device()])
    await eventually { fixture.client.identityRequests == 1 && fixture.updates.last?.count == 1 }
    precondition(fixture.updates.last?.first?.displayTitle == "Generic model")
    precondition(fixture.manager.latestDevices.isEmpty, "Preview readiness must not authorize shell-dependent captures")
  }

  static func matchingPreservesOneRow(_ fixture: Fixture) async {
    let rowID = fixture.manager.entries[0].id
    fixture.tracker.update([device()])
    await eventually { fixture.client.identityRequests == 1 }
    precondition(fixture.manager.entries.count == 1)
    precondition(fixture.manager.entries[0].id == rowID)
    precondition(fixture.manager.entries[0].detail == nil, "Pending matching must not display a lock warning")
    await fixture.client.identityGate.open()
    await eventually { fixture.manager.connectedDevices.first?.displayTitle == "Test Tablet" }
    precondition(fixture.manager.entries.count == 1 && fixture.manager.entries[0].id == rowID)
    precondition(fixture.adb.client.bootRequests == 0, "Matching must not wait for the blocked ADB refresh")
  }

  static func bootStatusUpdatesAfterIdentity(_ fixture: Fixture) async {
    await fixture.connect()
    await fixture.adb.client.connectionsGate.open()
    await eventually { !fixture.manager.isRefreshing }
    let refresh = Task { await fixture.manager.refresh() }
    await eventually { fixture.adb.client.bootRequests > 0 }
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
    await eventually { fixture.updates.last?.first?.displayTitle == "Renamed Tablet" }
    precondition(fixture.manager.latestDevices[0].displayTitle == "Renamed Tablet")
    precondition(captured.displayTitle == "Test Tablet", "Existing capture snapshots must retain their name")
    precondition(fixture.manager.latestDevices[0].avdName == "Test Tablet", "Renaming must preserve AVD identity")
  }

  static func failedMatchingLeavesDeviceAccessible(_ fixture: Fixture) async {
    fixture.client.resolvesSerial = false
    await fixture.client.identityGate.open()
    fixture.tracker.update([device()])
    await eventually { fixture.client.identityRequests == 1 && fixture.manager.matchingSerials.isEmpty }
    precondition(fixture.manager.entries.contains { $0.serial == "emulator-5554" })
  }

  static func reusedTransportDiscardsOldProperties(_ fixture: Fixture) async {
    await fixture.connect(ready: true)
    fixture.client.identityGate = TestGate()
    fixture.tracker.update([device(transportID: "2")])
    await eventually { fixture.manager.connectedDevices.first?.transportID == "2" }
    precondition(fixture.manager.connectedDevices[0].displayTitle == "Generic model")
    precondition(fixture.manager.latestDevices.isEmpty)
  }

  static func staleMatchingCannotRestoreOldTransport(_ fixture: Fixture) async {
    fixture.tracker.update([device(transportID: "3")])
    await eventually { fixture.client.identityRequests == 1 }
    fixture.tracker.update([device(transportID: "4")])
    await eventually { fixture.client.identityRequests == 2 }
    await fixture.client.identityGate.open()
    await eventually { fixture.manager.matchingSerials.isEmpty && fixture.manager.connectedDevices.first?.displayName != nil }
    precondition(fixture.manager.connectedDevices[0].transportID == "4")
    precondition(fixture.manager.entries.count == 1)
  }

  static func disconnectRemovesCurrentDevices(_ fixture: Fixture) async {
    await fixture.connect(ready: true)
    fixture.tracker.update([], ready: true)
    await eventually { fixture.manager.connectedDevices.isEmpty && fixture.manager.latestDevices.isEmpty }
  }

  static func device(avdName: String? = nil, transportID: String = "1") -> Device {
    Device(
      id: "emulator-5554", model: "Generic model", androidVersion: "", vendorModel: nil,
      manufacturer: nil, avdName: avdName, transportID: transportID
    )
  }

  static func eventually(line: UInt = #line, _ condition: () -> Bool) async {
    for _ in 0 ..< 10000 {
      if condition() { return }
      await Task.yield()
    }
    fatalError("Expected inventory update did not arrive at line \(line)")
  }

  @MainActor
  final class Fixture {
    let adb = ADBService()
    let tracker = DeviceTracker()
    let client = EmulatorClient()
    let manager: DeviceManager
    var updates: [[Device]] = []
    private var observer: Task<Void, Never>?

    init() {
      manager = DeviceManager(adb: adb, deviceTracker: tracker, client: client)
    }

    func start() async {
      let stream = manager.previewDeviceStream()
      observer = Task {
        for await devices in stream {
          updates.append(devices)
        }
      }
      await eventually { self.manager.hasLoaded && self.adb.client.connectionRequests > 0 }
    }

    func connect(ready: Bool = false) async {
      await client.identityGate.open()
      tracker.update([device(avdName: ready ? "Test Tablet" : nil)], ready: ready)
      await eventually {
        self.manager.connectedDevices.first?.displayName == "Test Tablet"
          && self.manager.matchingSerials.isEmpty
          && (!ready || self.manager.latestDevices.count == 1)
      }
    }

    func allowRefresh() async {
      await adb.client.connectionsGate.open()
      await adb.client.bootGate.open()
      await eventually { !self.manager.isRefreshing }
    }

    func stop() async {
      manager.shutdown()
      observer?.cancel()
      await client.identityGate.open()
      await adb.client.connectionsGate.open()
      await adb.client.bootGate.open()
      await observer?.value
      await eventually { !self.manager.isRefreshing }
    }
  }
}
