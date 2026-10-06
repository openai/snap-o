import Foundation

@MainActor
struct CaptureBatchTests {
  static func run(root: URL, video: URL) async throws {
    try await runTestCase("stopDoesNotWaitForAnotherDeviceStartup") {
      try await stopDoesNotWaitForAnotherDeviceStartup(root: root, video: video)
    }
    try await runTestCase("screenshotPublishesEachStableItem") {
      try await screenshotPublishesEachStableItem(root: root, video: video)
    }
    try await runTestCase("screenshotFailureKeepsItsSlot") {
      try await screenshotFailureKeepsItsSlot(root: root, video: video)
    }
  }

  private static func stopDoesNotWaitForAnotherDeviceStartup(root: URL, video: URL) async throws {
    let devices = RecordingTests.makeDevices()
    let slowStartup = TestGate()
    let adb = ADBService(video: video)
    let fixture = RecordingTests.Fixture(root: root, video: video) { device, bugReport in
      if device.id == devices[1].id { await slowStartup.wait() }
      let session = try await adb.startScreenrecord(deviceID: device.id, bugReport: bugReport)
      return ADBScreenRecording(session: session, adb: adb)
    }
    let batch = fixture.recording(for: devices)
    batch.start()
    let ids = batch.items.map(\.id)
    precondition(batch.items.count == 2)
    for item in batch.items {
      guard case .pending = item.state else { preconditionFailure("Targets must exist before startup") }
    }
    await slowStartup.waitUntilEntered()
    await waitForObservedTestState {
      if case .recording = batch.items[0].state { return true }
      return false
    }
    let finished = TestValue(false)
    let stop = await startTestTask {
      await batch.beginFinalization(discarding: false).value
      finished.value = true
    }
    await waitForObservedTestState { batch.items[0].media != nil }
    let stops = await adb.stops
    precondition(stops == [devices[0].id], "A must stop before B finishes startup")
    precondition(!finished.value && !batch.isComplete, "The batch still owns pending B")
    await slowStartup.open()
    await stop.value
    precondition(batch.items.map(\.id) == ids, "Results must fill the original slots")
    precondition(batch.items.compactMap(\.media).map(\.device.id) == devices.map(\.id))
    precondition(batch.isComplete)
    await batch.close()
  }

  private static func screenshotPublishesEachStableItem(root: URL, video: URL) async throws {
    let devices = RecordingTests.makeDevices()
    let fixture = RecordingTests.Fixture(root: root, video: video)
    let slowCapture = TestGate()
    await fixture.adb.blockScreenshot(for: devices[1].id, on: slowCapture)
    let batch = fixture.screenshots(for: devices)
    batch.start()
    let ids = batch.items.map(\.id)
    await slowCapture.waitUntilEntered()
    await waitForObservedTestState { batch.items[0].media != nil }
    guard case .pending = batch.items[1].state else { preconditionFailure("B should still be pending") }
    precondition(!batch.isComplete)
    await slowCapture.open()
    await batch.waitForCompletion()
    await waitForObservedTestState { batch.isComplete }
    precondition(batch.items.map(\.id) == ids)
    precondition(batch.items.compactMap(\.media).map(\.device.id) == devices.map(\.id))
    await batch.close()
  }
  private static func screenshotFailureKeepsItsSlot(root: URL, video: URL) async throws {
    let healthy = RecordingTests.makeDevices()[0]
    let unavailable = Device(
      id: "unavailable", model: "Unavailable", androidVersion: "16",
      vendorModel: nil, manufacturer: nil, avdName: nil
    )
    let fixture = RecordingTests.Fixture(root: root, video: video)
    let batch = fixture.screenshots(for: [healthy, unavailable])
    batch.start()
    let ids = batch.items.map(\.id)
    await batch.waitForCompletion()
    precondition(batch.items.map(\.id) == ids, "Failure must not remove or replace an item")
    precondition(batch.items[0].media?.device.id == healthy.id)
    guard case .failed = batch.items[1].state else {
      preconditionFailure("The unavailable device must report its failure in its own slot")
    }
    await batch.close()
  }

}
