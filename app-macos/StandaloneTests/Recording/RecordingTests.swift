@preconcurrency import AVFoundation
import Clocks
import Dependencies
import Foundation

@main
@MainActor
struct RecordingTests {
  static let devices = makeDevices()

  static func makeDevices() -> [Device] {
    ["Device A", "Device B"].map {
      Device(
        id: $0, model: $0, androidVersion: "16", vendorModel: nil, manufacturer: nil, avdName: nil,
        connection: DeviceTarget(serial: $0, transportID: "1")
      )
    }
  }

  static let options = RecordingOptions(recordsBugReport: false, showsTouches: false)

  static func main() async throws {
    try await withDependencies {
      $0.context = .test
      $0.staticRecording.readFrame = { _ in nil }
      $0.continuousClock = TestClock()
    } operation: {
      let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: root) }
      let video = root.appendingPathComponent("fixture.mp4")
      try Data("valid recording".utf8).write(to: video)
      try await runTestCase("failedDeviceLeavesHealthyRecordingActive") {
        try await failedDeviceLeavesHealthyRecordingActive(root: root, video: video)
      }
      try await runTestCase("collectionFailurePreservesHealthyRecording") {
        try await collectionFailurePreservesHealthyRecording(root: root, video: video)
      }
      try await runTestCase("disconnectedDeviceLeavesHealthyRecordingActive") {
        try await disconnectedDeviceLeavesHealthyRecordingActive(root: root, video: video)
      }
      try await runTestCase("replacementDoesNotJoinRecording") {
        try await replacementDoesNotJoinRecording(root: root, video: video)
      }
      try await runTestCase("cancellationDoesNotSignalEndedSession") {
        try await cancellationDoesNotSignalEndedSession(root: root, video: video)
      }
      try await runTestCase("endedSessionRestoresTouchIndicators") {
        try await endedSessionRestoresTouchIndicators(root: root, video: video)
      }
      try await runTestCase("unconfirmedStopPreservesRemoteRecording") {
        try await unconfirmedStopPreservesRemoteRecording(root: root, video: video)
      }
      try await runTestCase("invalidDownloadPreservesRemoteRecording") {
        try await invalidDownloadPreservesRemoteRecording(root: root)
      }
      try await runTestCase("confirmedRecordingRemovesRemoteCopy") {
        try await confirmedRecordingRemovesRemoteCopy(root: root, video: video)
      }
      try await runTestCase("finalDeviceFailureCompletesRecording") {
        try await finalDeviceFailureCompletesRecording(root: root, video: video)
      }
      try await runTestCase("oneRecordingPerEmulatorConnection") {
        try await oneRecordingPerEmulatorConnection(root: root, video: video)
      }
      try await runTestCase("bugReportRecordingIsExclusive") {
        try await bugReportRecordingIsExclusive(root: root, video: video)
      }
      try await runTestCase("unstartedRecordingCanBeClosed") {
        try await unstartedRecordingCanBeClosed(root: root, video: video)
      }
      try await runTestCase("lateStartupCancellationAndShutdown") {
        try await lateStartupCancellationAndShutdown(root: root, video: video)
      }
      try await runTestCase("failedStartupPreservesHealthyTargets") {
        try await failedStartupPreservesHealthyTargets(root: root, video: video)
      }
      try await runTestCase("finishAndCancelJoinCollection") {
        try await finishAndCancelJoinCollection(root: root, video: video)
      }
      try await runTestCase("disconnectedStartupCannotRejoin") {
        try await disconnectedStartupCannotRejoin(root: root, video: video)
      }
      try await runTestCase("screenshotSharesNormalRecording") {
        try await screenshotSharesNormalRecording(root: root, video: video)
      }
      try await runTestCase("pendingScreenshotDoesNotBlockOtherDevices") {
        try await pendingScreenshotDoesNotBlockOtherDevices(root: root, video: video)
      }
      try await runTestCase("screenshotCancellationJoinsDeviceWork") {
        try await screenshotCancellationJoinsDeviceWork(root: root, video: video)
      }
      try await runTestCase("screenshotFailureReleasesReservation") {
        try await screenshotFailureReleasesReservation(root: root, video: video)
      }
      try await runTestCase("screenshotShutdownJoinsWork") {
        try await screenshotShutdownJoinsWork(root: root, video: video)
      }
      try await runTestCase("startupRefreshesOldScreenshotsWithoutDuplicatingPendingWork") {
        try await startupRefreshesOldScreenshotsWithoutDuplicatingPendingWork(root: root, video: video)
      }
      try await runTestCase("screenshotReservationCanBeDiscarded") {
        try await screenshotReservationCanBeDiscarded(root: root, video: video)
      }
      try await runTestCase("shutdownCancelsQueuedRecordingStartup") {
        try await shutdownCancelsQueuedRecordingStartup(root: root, video: video)
      }
      try await runTestCase("bugReportConflictAffectsOnlyItsDevice") {
        try await bugReportConflictAffectsOnlyItsDevice(root: root, video: video)
      }
      try await runTestCase("recordingMetadataKeepsTheOriginalConnection") {
        try await recordingMetadataKeepsTheOriginalConnection(root: root)
      }
      try await runTestCase("RecordingTeardownTests.run") {
        try await RecordingTeardownTests.run(root: root, video: video)
      }
      print("Capture tests passed")
    }
  }

  static func recordingMetadataKeepsTheOriginalConnection(root: URL) async throws {
    let video = root.appendingPathComponent("placeholder.mp4")
    try Data("valid recording".utf8).write(to: video)
    for disconnected in [false, true] {
      let target = DeviceTarget(serial: "metadata-test", transportID: "1")
      let device = Device(
        id: target.serial, model: "Metadata test", androidVersion: "16", vendorModel: nil,
        manufacturer: nil, avdName: nil, connection: target
      )
      let fixture = Fixture(root: root, video: video)
      let capture = withDependencies {
        $0.videoFiles.inspect = { _ in VideoFileInfo(duration: 1, size: CGSize(width: 16, height: 16)) }
      } operation: { fixture.recording(for: device, readsVideoMetadata: true) }
      capture.start()
      _ = await capture.startup?.value
      if disconnected { target.invalidate() }
      await capture.beginFinalization(discarding: false).value
      guard let media = capture.media else { preconditionFailure("Missing connection metadata must not lose a playable recording") }
      precondition(media.media.densityScale == (disconnected ? nil : 160))
      let requests = await fixture.adb.densityRequests
      precondition(requests == (disconnected ? [] : [target.serial]))
      await capture.close()
    }
  }

  @MainActor
  struct Fixture {
    let adb: ADBService
    let history: CaptureHistoryRepository
    let coordinator = CaptureCoordinator()
    let fileStore: FileStore
    let start: RecordingCapture.StartRecording?
    let timestamps = CaptureTimestampSource()

    init(root: URL, video: URL, startRecording: RecordingCapture.StartRecording? = nil) {
      let directory = root.appendingPathComponent(UUID().uuidString)
      adb = ADBService(video: video)
      history = CaptureHistoryRepository(root: directory.appendingPathComponent("history"))
      fileStore = FileStore(baseDir: directory.appendingPathComponent("preview"))
      start = startRecording
    }

    func recording(
      for device: Device, options: RecordingOptions = RecordingTests.options, readsVideoMetadata: Bool = false
    ) -> RecordingCapture {
      let adb = adb
      return RecordingCapture(
        device: device, options: options, adb: adb, fileStore: fileStore,
        coordinator: coordinator,
        startRecording: start ?? { device, bugReport in
          let session = try await adb.startScreenrecord(deviceID: device.id, bugReport: bugReport)
          return ADBScreenRecording(session: session, adb: adb)
        },
        loadRecording: readsVideoMetadata ? nil : { @Sendable url, device, capturedAt in
          guard try Data(contentsOf: url) == Data("valid recording".utf8) else { throw CocoaError(.fileReadCorruptFile) }
          return CaptureMedia(device: device, media: .video(
            url: url, capturedAt: capturedAt, display: DisplayInfo(size: CGSize(width: 16, height: 16), densityScale: 1)
          ))
        },
        timestampSource: timestamps
      )
    }

    func startRecording(for device: Device, options: RecordingOptions = RecordingTests.options) async -> RecordingCapture {
      let capture = recording(for: device, options: options)
      capture.start()
      _ = await capture.startup?.value
      return capture
    }

    func screenshot(for device: Device) -> ScreenshotCapture {
      ScreenshotCapture(
        device: device, screenshots: ScreenshotService(adb: adb, fileStore: fileStore), fileStore: fileStore,
        coordinator: coordinator
      )
    }

    func captureScreenshot(for device: Device) async -> ScreenshotCapture {
      let capture = screenshot(for: device)
      capture.start()
      await capture.waitForCompletion()
      return capture
    }

    func expectReserved(_ device: Device) throws {
      do {
        let lease = try coordinator.acquire(target: device.requireConnection(), for: .bugReportRecording)
        coordinator.release(lease)
        preconditionFailure("The recording must retain its connection until cleanup finishes")
      } catch CaptureCoordinationError.deviceBusy {}
    }

    func waitForFailure(in capture: RecordingCapture) async {
      await waitForObservedTestState {
        if case .failed = capture.state { return true }
        if capture.warning != nil { return true }
        return false
      }
    }
  }

  static func screenshotReservationCanBeDiscarded(root: URL, video: URL) async throws {
    let fixture = Fixture(root: root, video: video)
    let capture = fixture.screenshot(for: devices[0])
    await capture.close()
    capture.start()
    let requests = await fixture.adb.screenshotRequests
    precondition(capture.isComplete && requests.isEmpty, "Closing an unstarted capture prevents later work")
    await fixture.coordinator.waitUntilIdle()
  }

  static func shutdownCancelsQueuedRecordingStartup(root: URL, video: URL) async throws {
    let fixture = Fixture(root: root, video: video) { _, _ in
      preconditionFailure("Closing queued startup must prevent device work")
    }
    let capture = fixture.recording(for: devices[0])
    capture.start()
    await capture.close()
    precondition(capture.isComplete && capture.media == nil)
    await fixture.coordinator.waitUntilIdle()
  }

  static func screenshotSharesNormalRecording(root: URL, video: URL) async throws {
    let fixture = Fixture(root: root, video: video)
    let recording = await fixture.startRecording(for: devices[0])
    let screenshot = await fixture.captureScreenshot(for: devices[0])
    precondition(screenshot.media != nil && !recording.isComplete)
    await screenshot.close()
    await recording.close()
    await fixture.coordinator.waitUntilIdle()
  }

  static func pendingScreenshotDoesNotBlockOtherDevices(root: URL, video: URL) async throws {
    let fixture = Fixture(root: root, video: video)
    let gate = TestGate()
    await fixture.adb.blockScreenshot(for: devices[0].id, on: gate)
    let screenshot = fixture.screenshot(for: devices[0])
    screenshot.start()
    await gate.waitUntilEntered()
    let recording = await fixture.startRecording(for: devices[1])
    let other = await fixture.captureScreenshot(for: devices[1])
    precondition(other.media != nil && !screenshot.isComplete && !recording.isComplete)
    await gate.open()
    await screenshot.waitForCompletion()
    await screenshot.close()
    await other.close()
    await recording.close()
    await fixture.coordinator.waitUntilIdle()
  }

  static func screenshotCancellationJoinsDeviceWork(root: URL, video: URL) async throws {
    let fixture = Fixture(root: root, video: video)
    let gate = TestGate()
    await fixture.adb.blockScreenshots(on: gate)
    let capture = fixture.screenshot(for: devices[0])
    capture.start()
    await gate.waitUntilEntered()
    let finished = TestValue(false)
    let cancellation = await startTestTask { await capture.close()
      finished.value = true
    }
    precondition(!finished.value, "Close must join pending device work")
    try fixture.expectReserved(devices[0])
    await gate.open()
    await cancellation.value
    precondition(capture.media == nil)
    await fixture.coordinator.waitUntilIdle()
  }

  static func screenshotFailureReleasesReservation(root: URL, video: URL) async throws {
    let fixture = Fixture(root: root, video: video)
    let failed = await fixture.captureScreenshot(for: Device(
      id: "offline", model: "Offline", androidVersion: "16", vendorModel: nil, manufacturer: nil, avdName: nil
    ))
    guard case .failed = failed.state else { preconditionFailure("Missing per-device failure") }
    let next = await fixture.captureScreenshot(for: devices[1])
    precondition(next.media != nil)
    await failed.close()
    await next.close()
    await fixture.coordinator.waitUntilIdle()
  }

  static func screenshotShutdownJoinsWork(root: URL, video: URL) async throws {
    let fixture = Fixture(root: root, video: video)
    let gate = TestGate()
    await fixture.adb.blockScreenshots(on: gate)
    let capture = fixture.screenshot(for: devices[0])
    capture.start()
    await gate.waitUntilEntered()
    fixture.coordinator.beginShutdown()
    let closed = TestValue(false)
    let shutdown = await startTestTask { await capture.close()
      closed.value = true
    }
    precondition(!closed.value)
    let rejected = await fixture.captureScreenshot(for: devices[0])
    guard case .failed = rejected.state else { preconditionFailure("Shutdown must reject captures") }
    do {
      _ = try fixture.coordinator.acquire(target: devices[0].requireConnection(), for: .screenshot)
      preconditionFailure("Shutdown must close capture admission")
    } catch CaptureCoordinationError.closed {}
    await gate.open()
    await shutdown.value
    precondition(capture.media == nil)
    await rejected.close()
    await fixture.coordinator.waitUntilIdle()
  }

  static func startupRefreshesOldScreenshotsWithoutDuplicatingPendingWork(root: URL, video: URL) async throws {
    for state in ["fresh", "expired", "pending", "replacement"] {
      let clock = TestClock()
      await withDependencies { $0.continuousClock = clock } operation: {
        let fixture = Fixture(root: root, video: video)
        let gate = TestGate()
        if state == "pending" { await fixture.adb.blockScreenshots(on: gate) }
        var batches: [ScreenshotCapture] = []
        let startup = StartupCapturePreparation(
          screenshots: { device in
            let capture = fixture.screenshot(for: device)
            batches.append(capture)
            return capture
          },
          livePreview: LivePreviewService()
        )
        let devices = makeDevices()
        startup.prepare(mode: .screenshot, device: devices[0])
        let first = batches[0]
        if state == "pending" {
          await gate.waitUntilEntered()
        } else {
          await first.waitForCompletion()
        }
        await clock.advance(by: state == "fresh" ? .milliseconds(999) : .seconds(2))
        let currentDevices = state == "replacement" ? makeDevices() : devices
        guard let claimed = startup.claimScreenshots(for: currentDevices[0]) else { preconditionFailure("Missing startup capture") }
        precondition((claimed === first) == (state == "fresh" || state == "pending"))
        precondition(startup.claimScreenshots(for: currentDevices[0]) == nil, "Only one window may claim preparation")
        await gate.open()
        await claimed.waitForCompletion()
        let requests = await fixture.adb.screenshotRequests
        precondition(requests.count == (state == "fresh" || state == "pending" ? 1 : 2))
        await startup.discard()
        await claimed.close()
      }
    }
  }

  static func bugReportConflictAffectsOnlyItsDevice(root: URL, video: URL) async throws {
    let fixture = Fixture(root: root, video: video)
    let busy = devices[1]
    let preview = try fixture.coordinator.acquire(target: busy.requireConnection(), for: .livePreview)
    let options = RecordingOptions(recordsBugReport: true, showsTouches: true)
    let rejected = await fixture.startRecording(for: busy, options: options)
    let healthy = await fixture.startRecording(for: devices[0], options: options)
    guard case .failed = rejected.state else { preconditionFailure("Reject the busy target") }
    guard case .recording = healthy.state else { preconditionFailure("Another window must keep recording") }
    let settings = await fixture.adb.touchSettings
    precondition(settings[busy.id] == nil, "Reject conflicting work before changing settings")
    await rejected.close()
    await healthy.close()
    fixture.coordinator.release(preview)
    await fixture.coordinator.waitUntilIdle()
  }

  static func oneRecordingPerEmulatorConnection(root: URL, video: URL) async throws {
    let fixture = Fixture(root: root, video: video)
    let emulator = Device(
      id: "emulator-5554", model: "Emulator", androidVersion: "16", vendorModel: nil, manufacturer: nil,
      avdName: nil, connection: DeviceTarget(serial: "emulator-5554", transportID: "7")
    )
    let preview = try fixture.coordinator.acquire(target: emulator.requireConnection(), for: .livePreview)
    let first = await fixture.startRecording(for: emulator)
    let second = await fixture.startRecording(for: emulator)
    guard case .failed = second.state else { preconditionFailure("Reject the busy emulator") }
    precondition(!first.isComplete)
    await second.close()
    await first.close()
    let next = await fixture.startRecording(for: emulator)
    guard case .recording = next.state else { preconditionFailure("Cleanup must release the emulator") }
    await next.close()
    fixture.coordinator.release(preview)
    await fixture.coordinator.waitUntilIdle()
  }

  static func bugReportRecordingIsExclusive(root: URL, video: URL) async throws {
    let fixture = Fixture(root: root, video: video)
    let capture = await fixture.startRecording(for: devices[0], options: RecordingOptions(recordsBugReport: true, showsTouches: false))
    do {
      _ = try fixture.coordinator.acquire(target: devices[0].requireConnection(), for: .livePreview)
      preconditionFailure("A bug-report recording must exclude previews on its connection")
    } catch CaptureCoordinationError.deviceBusy {}
    await capture.close()
    let resumed = try fixture.coordinator.acquire(target: devices[0].requireConnection(), for: .livePreview)
    fixture.coordinator.release(resumed)
    await fixture.coordinator.waitUntilIdle()
  }

  static func failedDeviceLeavesHealthyRecordingActive(root: URL, video: URL) async throws {
    let devices = makeDevices()
    let fixture = Fixture(root: root, video: video)
    let failed = await fixture.startRecording(for: devices[0])
    let healthy = await fixture.startRecording(for: devices[1])
    await fixture.adb.endUnexpectedly(devices[0].id)
    await fixture.waitForFailure(in: failed)
    guard case .recording = healthy.state else { preconditionFailure("Another window must keep recording") }
    let stops = await fixture.adb.stops
    precondition(stops.isEmpty)
    await failed.close()
    await healthy.close()
  }

  static func collectionFailurePreservesHealthyRecording(root: URL, video: URL) async throws {
    let fixture = Fixture(root: root, video: video)
    let failed = await fixture.startRecording(for: devices[0])
    let healthy = await fixture.startRecording(for: devices[1])
    await fixture.adb.failCollection(devices[0].id)
    await failed.beginFinalization(discarding: false).value
    guard case .failed = failed.state else { preconditionFailure("Failed download must remain visible") }
    guard case .recording = healthy.state else { preconditionFailure("Another window must keep recording") }
    await healthy.beginFinalization(discarding: false).value
    guard let url = healthy.media?.media.url else { preconditionFailure("Missing healthy recording") }
    precondition(FileManager.default.fileExists(atPath: url.path))
    await failed.close()
    await healthy.close()
  }

  static func disconnectedDeviceLeavesHealthyRecordingActive(root: URL, video: URL) async throws {
    let devices = makeDevices()
    let fixture = Fixture(root: root, video: video)
    let failed = await fixture.startRecording(for: devices[0])
    let healthy = await fixture.startRecording(for: devices[1])
    devices[0].connection?.invalidate()
    await fixture.waitForFailure(in: failed)
    guard case .recording = healthy.state else { preconditionFailure("Another window must keep recording") }
    let stops = await fixture.adb.stops
    precondition(stops.isEmpty)
    await failed.close()
    await healthy.close()
  }

  static func replacementDoesNotJoinRecording(root: URL, video: URL) async throws {
    let devices = makeDevices()
    let fixture = Fixture(root: root, video: video)
    let capture = await fixture.startRecording(for: devices[0], options: options)
    let replacement = Device(
      id: devices[0].id, model: "Replacement", androidVersion: "16", vendorModel: nil,
      manufacturer: nil, avdName: nil, connection: DeviceTarget(serial: devices[0].id, transportID: "2")
    )
    devices[0].connection?.invalidate()
    await fixture.waitForFailure(in: capture)
    await capture.close()
    let stops = await fixture.adb.stops
    precondition(stops.isEmpty, "The replacement must never join the old recording")
    let next = await fixture.startRecording(for: replacement, options: options)
    await next.close()
  }

  static func cancellationDoesNotSignalEndedSession(root: URL, video: URL) async throws {
    let fixture = Fixture(root: root, video: video)
    let capture = await fixture.startRecording(for: devices[0], options: options)
    await fixture.adb.endUnexpectedly(devices[0].id)
    await fixture.waitForFailure(in: capture)

    await capture.close()
    let stops = await fixture.adb.stops
    precondition(stops.isEmpty, "An ended recording must not receive a stop signal")
  }

  static func endedSessionRestoresTouchIndicators(root: URL, video: URL) async throws {
    let fixture = Fixture(root: root, video: video)
    let options = RecordingOptions(recordsBugReport: false, showsTouches: true)
    let ended = await fixture.startRecording(for: devices[0], options: options)
    let healthy = await fixture.startRecording(for: devices[1], options: options)
    await fixture.adb.endUnexpectedly(devices[0].id)
    await fixture.waitForFailure(in: ended)
    await waitForActorTestState { await fixture.adb.touchSettings[devices[0].id] == false }
    let settings = await fixture.adb.touchSettings
    precondition(settings == [devices[0].id: false, devices[1].id: true])
    await ended.close()
    await healthy.close()
  }

  static func unconfirmedStopPreservesRemoteRecording(root: URL, video: URL) async throws {
    let fixture = Fixture(root: root, video: video)
    let capture = await fixture.startRecording(for: devices[0], options: options)
    await fixture.adb.failStop(devices[0].id)
    await capture.beginFinalization(discarding: false).value

    let removed = await fixture.adb.removedRecordings
    precondition(removed.isEmpty, "An unconfirmed stop must preserve the device copy")
  }

  static func invalidDownloadPreservesRemoteRecording(root: URL) async throws {
    let invalidVideo = root.appendingPathComponent("incomplete.mp4")
    try Data("incomplete recording".utf8).write(to: invalidVideo)
    let fixture = Fixture(root: root, video: invalidVideo)
    let capture = await fixture.startRecording(for: devices[0], options: options)
    await capture.beginFinalization(discarding: false).value

    let removed = await fixture.adb.removedRecordings
    precondition(removed.isEmpty, "An unusable download must preserve the device copy")
  }

  static func confirmedRecordingRemovesRemoteCopy(root: URL, video: URL) async throws {
    let fixture = Fixture(root: root, video: video)
    let capture = await fixture.startRecording(for: devices[0], options: options)
    await capture.beginFinalization(discarding: false).value

    let removed = await fixture.adb.removedRecordings
    precondition(removed == [devices[0].id], "A confirmed stop and usable local copy allow remote cleanup")
  }

  static func finalDeviceFailureCompletesRecording(root: URL, video: URL) async throws {
    let fixture = Fixture(root: root, video: video)
    let capture = await fixture.startRecording(for: devices[0])
    await fixture.adb.endUnexpectedly(devices[0].id)
    await waitForObservedTestState { capture.isComplete }
    let removed = await fixture.adb.removedRecordings
    precondition(capture.media != nil && removed.isEmpty)
    precondition(capture.warning != nil, "A recovered file must keep its unexpected-stop warning")
    await capture.close()
    await fixture.coordinator.waitUntilIdle()
  }

  static func unstartedRecordingCanBeClosed(root: URL, video: URL) async throws {
    let fixture = Fixture(root: root, video: video) { _, _ in preconditionFailure("Unstarted capture must not acquire a device") }
    let capture = fixture.recording(for: devices[0])
    await capture.close()
    capture.start()
    precondition(capture.isComplete && capture.media == nil)
    await fixture.coordinator.waitUntilIdle()
  }

  static func lateStartupCancellationAndShutdown(root: URL, video: URL) async throws {
    for shutdown in [false, true] {
      let gate = TestGate()
      let adb = ADBService(video: video)
      let fixture = Fixture(root: root, video: video) { device, bugReport in
        await gate.wait()
        let session = try await adb.startScreenrecord(deviceID: device.id, bugReport: bugReport)
        return ADBScreenRecording(session: session, adb: adb)
      }
      let capture = fixture.recording(for: devices[0])
      capture.start()
      await gate.waitUntilEntered()
      if shutdown { fixture.coordinator.beginShutdown() }
      let ending = Task { await capture.close() }
      await waitForObservedTestState { capture.phase == .cancelling }
      if !shutdown {
        try fixture.expectReserved(devices[0])
      } else {
        let rejected = await fixture.startRecording(for: devices[1])
        await waitForObservedTestState { rejected.isComplete }
        guard case .failed = rejected.state else { preconditionFailure("Shutdown must reject new work") }
        await rejected.close()
      }
      await gate.open()
      await ending.value
      let removed = await adb.removedRecordings
      precondition(capture.media == nil && removed == [devices[0].id])
      await fixture.coordinator.waitUntilIdle()
    }
  }

  static func failedStartupPreservesHealthyTargets(root: URL, video: URL) async throws {
    let adb = ADBService(video: video)
    let failingID = devices[1].id
    let fixture = Fixture(root: root, video: video) { device, bugReport in
      if device.id == failingID { throw CocoaError(.fileReadUnknown) }
      let session = try await adb.startScreenrecord(deviceID: device.id, bugReport: bugReport)
      return ADBScreenRecording(session: session, adb: adb)
    }
    let failed = await fixture.startRecording(for: devices[1])
    let healthy = await fixture.startRecording(for: devices[0])
    guard case .failed = failed.state else { preconditionFailure("The startup error must remain visible") }
    guard case .recording = healthy.state else { preconditionFailure("Another device can still record") }
    let stops = await adb.stops
    precondition(stops.isEmpty)
    await failed.close()
    await healthy.close()
  }

  static func finishAndCancelJoinCollection(root: URL, video: URL) async throws {
    let fixture = Fixture(root: root, video: video)
    let capture = await fixture.startRecording(for: devices[0])
    let gate = TestGate()
    await fixture.adb.blockDownload(on: gate)
    let first = capture.beginFinalization(discarding: false)
    await gate.waitUntilEntered()
    let finished = TestValue(false)
    let again = await startTestTask { await capture.beginFinalization(discarding: false).value
      finished.value = true
    }
    let closed = TestValue(false)
    let close = await startTestTask { await capture.close()
      closed.value = true
    }
    precondition(!finished.value && !closed.value)
    await gate.open()
    await first.value
    await again.value
    await close.value
    let removed = await fixture.adb.removedRecordings
    precondition(capture.media != nil && removed == [devices[0].id])
    await fixture.coordinator.waitUntilIdle()
  }

  static func disconnectedStartupCannotRejoin(root: URL, video: URL) async throws {
    let devices = makeDevices()
    let gate = TestGate()
    let adb = ADBService(video: video)
    let fixture = Fixture(root: root, video: video) { device, bugReport in
      await gate.wait()
      let session = try await adb.startScreenrecord(deviceID: device.id, bugReport: bugReport)
      return ADBScreenRecording(session: session, adb: adb)
    }
    let capture = fixture.recording(for: devices[0])
    capture.start()
    await gate.waitUntilEntered()
    devices[0].connection?.invalidate()
    await gate.open()
    _ = await capture.startup?.value
    await capture.beginFinalization(discarding: false).value
    guard case .failed = capture.state else { preconditionFailure("An old connection cannot rejoin") }
    precondition(capture.media == nil)
    await capture.close()
    await fixture.coordinator.waitUntilIdle()
  }
}
