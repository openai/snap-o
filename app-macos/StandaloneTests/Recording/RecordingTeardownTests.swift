import Clocks
import ConcurrencyExtras
import Dependencies
import Foundation

@MainActor
struct RecordingTeardownTests {
  static func run(root: URL, video: URL) async throws {
    try await withMainSerialExecutor {
      try await completionJoinsMonitors(root: root, video: video)
      try await completionJoinsTouchRestoration(root: root, video: video)
      try await automaticFinishJoinsEndedCleanup(root: root, video: video)
      try await slowEndedCleanupDoesNotDelayHealthyStop(root: root, video: video)
    }
  }

  private static func completionJoinsMonitors(root: URL, video: URL) async throws {
    for ending in ["finish", "cancel", "shutdown"] {
      let monitor = TestGate()
      let recording = ControlledRecording(video: video, monitorGate: monitor)
      let fixture = RecordingTests.Fixture(root: root, video: video) { _, _ in recording }
      let batch = await fixture.startRecording(for: [RecordingTests.devices[0]], options: RecordingTests.options)
      await waitForActorTestState { await recording.waitsStarted == 1 }
      let finished = TestValue(false)
      let first = await startTestTask {
        switch ending {
        case "finish": await batch.beginFinalization(discarding: false).value
        case "cancel": await batch.close()
        default: fixture.coordinator.beginShutdown(); await batch.close()
        }
        finished.value = true
      }
      await waitForActorTestState { await recording.closesCompleted > 0 }
      await monitor.waitUntilEntered()
      precondition(!finished.value, "Close must wait for the recording monitor during \(ending)")
      if ending != "shutdown" { try fixture.expectReserved(RecordingTests.devices[0]) }
      let repeatedFinished = TestValue(false)
      let repeated = await startTestTask {
        await batch.close()
        repeatedFinished.value = true
      }
      precondition(!repeatedFinished.value, "Repeated terminal calls must join monitor cleanup")
      await monitor.open()
      await first.value
      await repeated.value
      let waitsFinished = await recording.waitsFinished
      precondition(waitsFinished == 1 && batch.isComplete)
      precondition(batch.items.compactMap(\.media).count == (ending == "finish" ? 1 : 0))
      await fixture.coordinator.waitUntilIdle()
    }
    print("Finish, cancel and shutdown join recording monitors before releasing admission")
  }

  private static func completionJoinsTouchRestoration(root: URL, video: URL) async throws {
    for ending in ["finish", "cancel", "shutdown"] {
      let clock = TestClock()
      try await withDependencies { $0.continuousClock = clock } operation: {
        let recording = ControlledRecording(video: video)
        let fixture = RecordingTests.Fixture(root: root, video: video) { _, _ in recording }
        let device = RecordingTests.devices[0]
        let batch = await fixture.startRecording(
          for: [device], options: RecordingOptions(recordsBugReport: false, showsTouches: true)
        )
        let gate = TestGate()
        await fixture.adb.blockTouchRestoration(on: gate)
        let finished = TestValue(false)
        let first = await startTestTask {
          switch ending {
          case "finish": await batch.beginFinalization(discarding: false).value
          case "cancel": await batch.close()
          default: fixture.coordinator.beginShutdown(); await batch.close()
          }
          finished.value = true
        }
        await gate.waitUntilEntered()
        first.cancel()
        await clock.advance(by: .seconds(5))
        let repeatedFinished = TestValue(false)
        let repeated = await startTestTask {
          await batch.close()
          repeatedFinished.value = true
        }
        precondition(
          !finished.value && !repeatedFinished.value,
          "Capture admission must survive pending restoration during \(ending)"
        )
        if ending != "shutdown" { try fixture.expectReserved(device) }
        await gate.open()
        await first.value
        await repeated.value
        let setting = await fixture.adb.touchSettings[device.id]
        precondition(setting == false && batch.isComplete)
        precondition(batch.items.compactMap(\.media).count == (ending == "finish" ? 1 : 0))
        await fixture.coordinator.waitUntilIdle()
      }
    }
    print("Finish, cancel and shutdown join touch restoration before releasing admission")
  }

  private static func automaticFinishJoinsEndedCleanup(root: URL, video: URL) async throws {
    let close = TestGate()
    let recording = ControlledRecording(video: video, closeGate: close)
    let fixture = RecordingTests.Fixture(root: root, video: video) { _, _ in recording }
    let batch = await fixture.startRecording(for: [RecordingTests.devices[0]], options: RecordingTests.options)
    await waitForActorTestState { await recording.waitsStarted == 1 }
    await recording.endUnexpectedly()
    await close.waitUntilEntered()
    precondition(batch.phase == .finishing)
    try fixture.expectReserved(RecordingTests.devices[0])
    let collected = await recording.saves
    precondition(collected == 0, "Ended-session cleanup precedes collection")
    let joined = TestValue(false)
    let waiter = await startTestTask {
      await batch.close()
      joined.value = true
    }
    precondition(!joined.value, "Cancel joins the automatic finish already in progress")
    await close.open()
    await waiter.value
    let stops = await recording.stops
    let waitsFinished = await recording.waitsFinished
    precondition(batch.items.compactMap(\.media).count == 1 && batch.items[0].warning != nil)
    precondition(stops == 0 && waitsFinished == 1)
    await fixture.coordinator.waitUntilIdle()
    print("The final recording failure finishes without a self-wait and joins ended-session cleanup")
  }

  private static func slowEndedCleanupDoesNotDelayHealthyStop(root: URL, video: URL) async throws {
    let close = TestGate()
    let failed = ControlledRecording(video: video, closeGate: close)
    let healthy = ControlledRecording(video: video)
    let failedDeviceID = RecordingTests.devices[0].id
    let fixture = RecordingTests.Fixture(root: root, video: video) { device, _ in
      device.id == failedDeviceID ? failed : healthy
    }
    let batch = await fixture.startRecording(for: RecordingTests.devices, options: RecordingTests.options)
    await failed.endUnexpectedly()
    await close.waitUntilEntered()
    precondition(batch.phase == .recording)
    let finished = TestValue(false)
    let cancellation = await startTestTask {
      await batch.close()
      finished.value = true
    }
    await waitForActorTestState { await healthy.closesCompleted == 1 }
    let healthyStops = await healthy.stops
    precondition(healthyStops == 1 && !finished.value)
    try fixture.expectReserved(RecordingTests.devices[0])
    await close.open()
    await cancellation.value
    let failedWaits = await failed.waitsFinished
    let healthyWaits = await healthy.waitsFinished
    precondition(failedWaits == 1 && healthyWaits == 1)
    await fixture.coordinator.waitUntilIdle()
    print("A slow failed-device cleanup does not delay stopping a healthy sibling")
  }
}

private actor ControlledRecording: ScreenRecording {
  nonisolated let id = UUID()
  private let video: URL
  private let stopped = TestGate()
  private let monitorGate: TestGate?
  private let closeGate: TestGate?
  private var failed = false
  private(set) var waitsStarted = 0
  private(set) var waitsFinished = 0
  private(set) var closesCompleted = 0
  private(set) var stops = 0
  private(set) var saves = 0

  init(video: URL, monitorGate: TestGate? = nil, closeGate: TestGate? = nil) {
    self.video = video
    self.monitorGate = monitorGate
    self.closeGate = closeGate
  }

  func waitUntilStopped() async throws {
    waitsStarted += 1
    testChanges.signal()
    await stopped.wait()
    await monitorGate?.wait()
    waitsFinished += 1
    testChanges.signal()
    if failed { throw CocoaError(.fileReadUnknown) }
  }

  func endUnexpectedly() async {
    failed = true
    await stopped.open()
  }

  func stop() async throws {
    stops += 1
    testChanges.signal()
    await stopped.open()
  }

  func save(to destination: URL) async throws {
    saves += 1
    testChanges.signal()
    try FileManager.default.copyItem(at: video, to: destination)
  }

  func remove() async {}

  func close() async {
    await closeGate?.wait()
    await stopped.open()
    closesCompleted += 1
    testChanges.signal()
  }
}
