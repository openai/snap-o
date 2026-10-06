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
      try await runTestCase("screenshotReusesCurrentPreload") {
        try await screenshotReusesCurrentPreload(root: root, video: video)
      }
      try await runTestCase("screenshotReplacesPreloadFromOldConnection") {
        try await screenshotReplacesPreloadFromOldConnection(root: root, video: video)
      }
      try await runTestCase("screenshotRefreshesExpiredPreload") {
        try await screenshotRefreshesExpiredPreload(root: root, video: video)
      }
      try await runTestCase("screenshotReservationCanBeDiscarded") {
        try await screenshotReservationCanBeDiscarded(root: root, video: video)
      }
      try await runTestCase("screenshotReservationCanBeFinished") {
        try await screenshotReservationCanBeFinished(root: root, video: video)
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
      try await CaptureBatchTests.run(root: root, video: video)
      print("Capture tests passed")
    }
  }

  static func recordingMetadataKeepsTheOriginalConnection(root: URL) async throws {
    let video = root.appendingPathComponent("playable.mp4")
    let writer = try AVAssetWriter(outputURL: video, fileType: .mp4)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
      AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 16, AVVideoHeightKey: 16
    ])
    let receiver = writer.inputPixelBufferReceiver(for: input, pixelBufferAttributes: nil)
    guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    writer.startSession(atSourceTime: .zero)
    let buffer = try CVMutablePixelBuffer(.init(
      pixelFormatType: .init(rawValue: kCVPixelFormatType_32BGRA), size: .init(width: 16, height: 16)
    ))
    try buffer.withUnsafeBuffer { pixel in
      CVPixelBufferLockBaseAddress(pixel, [])
      defer { CVPixelBufferUnlockBaseAddress(pixel, []) }
      guard let bytes = CVPixelBufferGetBaseAddress(pixel) else { throw CocoaError(.fileWriteUnknown) }
      memset(bytes, 0, CVPixelBufferGetDataSize(pixel))
    }
    try await receiver.append(CVReadOnlyPixelBuffer(buffer), with: .zero)
    writer.endSession(atSourceTime: CMTime(value: 1, timescale: 1))
    receiver.finish()
    await writer.finishWriting()
    guard writer.status == .completed else { throw writer.error ?? CocoaError(.fileWriteUnknown) }

    for disconnected in [false, true] {
      let target = DeviceTarget(serial: "metadata-test", transportID: "1")
      let device = Device(
        id: target.serial, model: "Metadata test", androidVersion: "16", vendorModel: nil,
        manufacturer: nil, avdName: nil, connection: target
      )
      let fixture = Fixture(root: root, video: video)
      let batch = fixture.recording(for: [device], readsVideoMetadata: true)
      batch.start()
      _ = await batch.startup?.value
      if disconnected { target.invalidate() }
      await batch.beginFinalization(discarding: false).value
      let media = batch.items.compactMap(\.media)
      precondition(media.count == 1, "Missing connection metadata must not lose a playable recording")
      precondition(media.first?.media.densityScale == (disconnected ? nil : 160))
      let requests = await fixture.adb.densityRequests
      precondition(requests == (disconnected ? [] : [target.serial]))
      await batch.close()

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
      for devices: [Device], options: RecordingOptions = RecordingTests.options, readsVideoMetadata: Bool = false
    ) -> RecordingCapture {
      let adb = adb
      return RecordingCapture(
        devices: devices, options: options, adb: adb, fileStore: fileStore,
        coordinator: coordinator, history: history,
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

    func startRecording(for devices: [Device], options: RecordingOptions = RecordingTests.options) async -> RecordingCapture {
      let batch = recording(for: devices, options: options)
      batch.start()
      _ = await batch.startup?.value
      return batch
    }

    func screenshots(for devices: [Device]) -> ScreenshotCapture {
      ScreenshotCapture(
        devices: devices, screenshots: ScreenshotService(adb: adb, fileStore: fileStore), fileStore: fileStore,
        history: history, coordinator: coordinator
      )
    }

    func captureScreenshots(for devices: [Device], reusing: [CaptureMedia] = []) async -> ScreenshotCapture {
      let batch = screenshots(for: devices)
      batch.start(reusing: reusing)
      await batch.waitForCompletion()
      return batch
    }

    func expectReserved(_ device: Device) throws {
      do {
        let lease = try coordinator.acquire(target: device.requireConnection(), for: .bugReportRecording)
        coordinator.release(lease)
        preconditionFailure("The recording must retain its connection until cleanup finishes")
      } catch CaptureCoordinationError.deviceBusy {}
    }

    func waitForFailure() async {
      for await snapshot in await history.updates() where snapshot.entries.first?.items.first?.failure != nil {
        return
      }
      preconditionFailure("History ended before the recording failure was published")
    }
  }

  static func screenshotReservationCanBeDiscarded(root: URL, video: URL) async throws {
    let fixture = Fixture(root: root, video: video)
    let batch = fixture.screenshots(for: devices)
    await batch.close()
    batch.start()
    let requests = await fixture.adb.screenshotRequests
    precondition(batch.isComplete && requests.isEmpty, "Closing an unstarted batch prevents later work")
    await fixture.coordinator.waitUntilIdle()
  }

  static func screenshotReservationCanBeFinished(root: URL, video: URL) async throws {
    let fixture = Fixture(root: root, video: video)
    let batch = fixture.screenshots(for: devices)
    await batch.beginFinalization(discarding: false).value
    batch.start()
    let requests = await fixture.adb.screenshotRequests
    precondition(batch.isComplete && batch.items.compactMap(\.media).isEmpty && requests.isEmpty)
    await batch.close()
  }

  static func shutdownCancelsQueuedRecordingStartup(root: URL, video: URL) async throws {
    let fixture = Fixture(root: root, video: video) { _, _ in
      preconditionFailure("Closing queued startup must prevent device work")
    }
    let batch = fixture.recording(for: devices)
    batch.start()
    await batch.close()
    precondition(batch.isComplete && batch.items.allSatisfy { $0.media == nil })
    await fixture.coordinator.waitUntilIdle()
  }

  static func screenshotSharesNormalRecording(root: URL, video: URL) async throws {
    let fixture = Fixture(root: root, video: video)
    let recording = await fixture.startRecording(for: [devices[0]])
    let screenshots = await fixture.captureScreenshots(for: devices)
    precondition(screenshots.items.compactMap(\.media).count == devices.count)
    precondition(!recording.isComplete, "Screenshots do not stop an existing recording")
    await screenshots.close()
    await recording.close()
    await fixture.coordinator.waitUntilIdle()
  }

  static func pendingScreenshotDoesNotBlockOtherDevices(root: URL, video: URL) async throws {
    let fixture = Fixture(root: root, video: video)
    let gate = TestGate()
    await fixture.adb.blockScreenshot(for: devices[0].id, on: gate)
    let screenshot = fixture.screenshots(for: [devices[0]])
    screenshot.start()
    await gate.waitUntilEntered()
    let recording = await fixture.startRecording(for: [devices[1]])
    let other = await fixture.captureScreenshots(for: [devices[1]])
    precondition(other.items.compactMap(\.media).count == 1 && !screenshot.isComplete && !recording.isComplete)
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
    let batch = fixture.screenshots(for: [devices[0]])
    batch.start()
    await gate.waitUntilEntered()
    let finished = TestValue(false)
    let cancellation = await startTestTask { await batch.close(); finished.value = true }
    precondition(!finished.value, "Close must join pending device work")
    try fixture.expectReserved(devices[0])
    await gate.open()
    await cancellation.value
    precondition(batch.items.compactMap(\.media).isEmpty)
    await fixture.coordinator.waitUntilIdle()
  }

  static func screenshotFailureReleasesReservation(root: URL, video: URL) async throws {
    let fixture = Fixture(root: root, video: video)
    let failed = await fixture.captureScreenshots(for: [Device(
      id: "offline", model: "Offline", androidVersion: "16", vendorModel: nil, manufacturer: nil, avdName: nil
    )])
    precondition(failed.items.count == 1)
    guard case .failed = failed.items[0].state else { preconditionFailure("Missing per-device failure") }
    let next = await fixture.captureScreenshots(for: [devices[1]])
    precondition(next.items.compactMap(\.media).count == 1)
    await failed.close()
    await next.close()
    await fixture.coordinator.waitUntilIdle()
  }

  static func screenshotShutdownJoinsWork(root: URL, video: URL) async throws {
    let fixture = Fixture(root: root, video: video)
    let gate = TestGate()
    await fixture.adb.blockScreenshots(on: gate)
    let batch = fixture.screenshots(for: devices)
    batch.start()
    await gate.waitUntilEntered(2)
    fixture.coordinator.beginShutdown()
    let closed = TestValue(false)
    let shutdown = await startTestTask { await batch.close(); closed.value = true }
    precondition(!closed.value)
    let rejected = await fixture.captureScreenshots(for: devices)
    precondition(rejected.items.count == devices.count)
    for item in rejected.items {
      guard case .failed = item.state else { preconditionFailure("Shutdown must reject every device") }
    }
    do {
      _ = try fixture.coordinator.acquire(target: devices[0].requireConnection(), for: .screenshot)
      preconditionFailure("Shutdown must close capture admission")
    } catch CaptureCoordinationError.closed {}
    await gate.open()
    await shutdown.value
    precondition(batch.items.compactMap(\.media).isEmpty)
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
          screenshots: { devices in
            let batch = fixture.screenshots(for: devices)
            batches.append(batch)
            return batch
          },
          livePreview: LivePreviewService()
        )
        let devices = makeDevices()
        startup.prepare(mode: .screenshot, devices: devices)
        let first = batches[0]
        if state == "pending" {
          await gate.waitUntilEntered(2)
        } else {
          await first.waitForCompletion()
        }
        await clock.advance(by: state == "fresh" ? .milliseconds(999) : .seconds(2))
        let currentDevices = state == "replacement" ? makeDevices() : devices
        guard let claimed = startup.claimScreenshots(for: currentDevices) else { preconditionFailure("Missing startup batch") }
        precondition((claimed === first) == (state == "fresh" || state == "pending"))
        precondition(startup.claimScreenshots(for: currentDevices) == nil, "Only one window may claim preparation")
        await gate.open()
        await claimed.waitForCompletion()
        let requests = await fixture.adb.screenshotRequests
        precondition(requests.count == (state == "fresh" || state == "pending" ? 2 : 4))
        await startup.discard()
        await claimed.close()
      }
    }
  }

  static func screenshotReusesCurrentPreload(root: URL, video: URL) async throws {
    let fixture = Fixture(root: root, video: video)
    let original = await fixture.captureScreenshots(for: devices)
    let reused = await fixture.captureScreenshots(for: devices, reusing: original.items.compactMap(\.media))
    precondition(reused.items.compactMap(\.media).map(\.id) == original.items.compactMap(\.media).map(\.id))
    let requests = await fixture.adb.screenshotRequests
    precondition(requests.count == devices.count, "A fresh preload needs no extra requests")
    await reused.close()
    await original.close()
  }

  static func screenshotReplacesPreloadFromOldConnection(root: URL, video: URL) async throws {
    let fixture = Fixture(root: root, video: video)
    let original = await fixture.captureScreenshots(for: devices)
    let replacement = Device(
      id: devices[0].id, model: devices[0].model, androidVersion: "16", vendorModel: nil,
      manufacturer: nil, avdName: nil, connection: DeviceTarget(serial: devices[0].id, transportID: "2")
    )
    let next = await fixture.captureScreenshots(for: [replacement, devices[1]], reusing: original.items.compactMap(\.media))
    precondition(next.items.compactMap(\.media).first?.device.connection == replacement.connection)
    precondition(next.items.compactMap(\.media).first?.id != original.items.compactMap(\.media).first?.id)
    precondition(next.items.compactMap(\.media).last?.id == original.items.compactMap(\.media).last?.id)
    let requests = await fixture.adb.screenshotRequests
    precondition(requests.count == devices.count + 1 && requests.last == replacement.id)
    await next.close()
    await original.close()
  }

  static func screenshotRefreshesExpiredPreload(root: URL, video: URL) async throws {
    let fixture = Fixture(root: root, video: video)
    let original = await fixture.captureScreenshots(for: devices)
    let stale = original.items.compactMap(\.media).map { capture in
      guard let url = capture.media.url else { preconditionFailure("Missing screenshot file") }
      return CaptureMedia(device: capture.device, media: .image(
        url: url, capturedAt: .distantPast, display: capture.media.common.display
      ))
    }
    let next = await fixture.captureScreenshots(for: devices, reusing: stale)
    precondition(next.items.compactMap(\.media).count == devices.count)
    precondition(Set(next.items.compactMap(\.media).map(\.id)).isDisjoint(with: stale.map(\.id)))
    let requests = await fixture.adb.screenshotRequests
    precondition(requests.count == devices.count * 2)
    await next.close()
    await original.close()
  }

  static func bugReportConflictAffectsOnlyItsDevice(root: URL, video: URL) async throws {
    let fixture = Fixture(root: root, video: video)
    let busy = devices[1]
    let preview = try fixture.coordinator.acquire(target: busy.requireConnection(), for: .livePreview)
    let recording = await fixture.startRecording(for: devices, options: RecordingOptions(recordsBugReport: true, showsTouches: true))
    guard case .failed = recording.items[1].state else { preconditionFailure("Busy target must fail independently") }
    guard case .recording = recording.items[0].state else { preconditionFailure("Healthy target must keep recording") }
    let settings = await fixture.adb.touchSettings
    precondition(settings[busy.id] == nil, "Reject conflicting work before changing settings")
    await recording.close()
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
    let first = await fixture.startRecording(for: [emulator])
    let second = await fixture.startRecording(for: [emulator, devices[0]])
    guard case .failed = second.items[0].state else { preconditionFailure("Reject only the busy emulator") }
    guard case .recording = second.items[1].state else { preconditionFailure("Another device must remain independent") }
    precondition(!first.isComplete)
    await second.close()
    await first.close()
    let next = await fixture.startRecording(for: [emulator])
    guard case .recording = next.items[0].state else { preconditionFailure("Cleanup must release the emulator") }
    await next.close()
    fixture.coordinator.release(preview)
    await fixture.coordinator.waitUntilIdle()
  }

  static func bugReportRecordingIsExclusive(root: URL, video: URL) async throws {
    let fixture = Fixture(root: root, video: video)
    let batch = await fixture.startRecording(for: [devices[0]], options: RecordingOptions(recordsBugReport: true, showsTouches: false))
    do {
      _ = try fixture.coordinator.acquire(target: devices[0].requireConnection(), for: .livePreview)
      preconditionFailure("A bug-report recording must exclude previews on its connection")
    } catch CaptureCoordinationError.deviceBusy {}
    await batch.close()
    let resumed = try fixture.coordinator.acquire(target: devices[0].requireConnection(), for: .livePreview)
    fixture.coordinator.release(resumed)
    await fixture.coordinator.waitUntilIdle()
  }

  static func failedDeviceLeavesHealthyRecordingActive(root: URL, video: URL) async throws {
    let fixture = Fixture(root: root, video: video)
    let batch = await fixture.startRecording(for: devices, options: options)
    await fixture.adb.endUnexpectedly(devices[0].id)
    await fixture.waitForFailure()
    let stops = await fixture.adb.stops
    precondition(stops.isEmpty, "A device failure must not stop healthy recordings")
    await batch.close()
  }

  static func collectionFailurePreservesHealthyRecording(root: URL, video: URL) async throws {
    let fixture = Fixture(root: root, video: video)
    let batch = await fixture.startRecording(for: devices)
    await fixture.adb.failCollection(devices[0].id)
    await batch.beginFinalization(discarding: false).value
    let media = batch.items.compactMap(\.media)
    precondition(media.map(\.device.id) == [devices[1].id])
    guard let url = media[0].media.url else { preconditionFailure("Missing recording file") }
    precondition(FileManager.default.fileExists(atPath: url.path))
    guard case .failed = batch.items[0].state else { preconditionFailure("Failed download must remain visible") }
    await batch.close()
  }

  static func disconnectedDeviceLeavesHealthyRecordingActive(root: URL, video: URL) async throws {
    let devices = makeDevices()
    let fixture = Fixture(root: root, video: video)
    let batch = await fixture.startRecording(for: devices, options: options)
    devices[0].connection?.invalidate()
    await fixture.waitForFailure()
    let stops = await fixture.adb.stops
    precondition(stops.isEmpty, "Disconnect must leave the other recording active")
    await batch.close()
  }

  static func replacementDoesNotJoinRecording(root: URL, video: URL) async throws {
    let devices = makeDevices()
    let fixture = Fixture(root: root, video: video)
    let batch = await fixture.startRecording(for: devices, options: options)
    let replacement = Device(
      id: devices[0].id, model: "Replacement", androidVersion: "16", vendorModel: nil,
      manufacturer: nil, avdName: nil, connection: DeviceTarget(serial: devices[0].id, transportID: "2")
    )
    devices[0].connection?.invalidate()
    await fixture.waitForFailure()
    await batch.close()
    let stops = await fixture.adb.stops
    precondition(stops == [devices[1].id], "Replacement must end only its original recording and never rejoin")
    let next = await fixture.startRecording(for: [replacement], options: options)
    await next.close()
  }

  static func cancellationDoesNotSignalEndedSession(root: URL, video: URL) async throws {
    let fixture = Fixture(root: root, video: video)
    let batch = await fixture.startRecording(for: devices, options: options)
    await fixture.adb.endUnexpectedly(devices[0].id)
    await fixture.waitForFailure()

    await batch.close()
    let stops = await fixture.adb.stops
    precondition(stops == [devices[1].id], "Only the active recording may receive a stop signal")
  }

  static func endedSessionRestoresTouchIndicators(root: URL, video: URL) async throws {
    let fixture = Fixture(root: root, video: video)
    let batch = await fixture.startRecording(
      for: devices, options: RecordingOptions(recordsBugReport: false, showsTouches: true)
    )
    await fixture.adb.endUnexpectedly(devices[0].id)
    await fixture.waitForFailure()

    let settings = await fixture.adb.touchSettings
    precondition(settings == [devices[0].id: false, devices[1].id: true], "Restore only the ended device's setting")
    await batch.close()
  }

  static func unconfirmedStopPreservesRemoteRecording(root: URL, video: URL) async throws {
    let fixture = Fixture(root: root, video: video)
    let batch = await fixture.startRecording(for: [devices[0]], options: options)
    await fixture.adb.failStop(devices[0].id)
    await batch.beginFinalization(discarding: false).value

    let removed = await fixture.adb.removedRecordings
    precondition(removed.isEmpty, "An unconfirmed stop must preserve the device copy")
  }

  static func invalidDownloadPreservesRemoteRecording(root: URL) async throws {
    let invalidVideo = root.appendingPathComponent("incomplete.mp4")
    try Data("incomplete recording".utf8).write(to: invalidVideo)
    let fixture = Fixture(root: root, video: invalidVideo)
    let batch = await fixture.startRecording(for: [devices[0]], options: options)
    await batch.beginFinalization(discarding: false).value

    let removed = await fixture.adb.removedRecordings
    precondition(removed.isEmpty, "An unusable download must preserve the device copy")
  }

  static func confirmedRecordingRemovesRemoteCopy(root: URL, video: URL) async throws {
    let fixture = Fixture(root: root, video: video)
    let batch = await fixture.startRecording(for: [devices[0]], options: options)
    await batch.beginFinalization(discarding: false).value

    let removed = await fixture.adb.removedRecordings
    precondition(removed == [devices[0].id], "A confirmed stop and usable local copy allow remote cleanup")
  }
  static func finalDeviceFailureCompletesRecording(root: URL, video: URL) async throws {
    let fixture = Fixture(root: root, video: video)
    let batch = await fixture.startRecording(for: [devices[0]])
    await fixture.adb.endUnexpectedly(devices[0].id)
    await waitForObservedTestState { batch.isComplete }
    let removed = await fixture.adb.removedRecordings
    precondition(batch.items.compactMap(\.media).count == 1 && removed.isEmpty)
    precondition(batch.items[0].warning != nil, "A recovered file must keep its unexpected-stop warning")
    await batch.close()
    await fixture.coordinator.waitUntilIdle()
  }

  static func unstartedRecordingCanBeClosed(root: URL, video: URL) async throws {
    let fixture = Fixture(root: root, video: video) { _, _ in preconditionFailure("Unstarted batch must not acquire a device") }
    let batch = fixture.recording(for: devices)
    precondition(batch.items.count == devices.count)
    await batch.close()
    batch.start()
    precondition(batch.isComplete && batch.items.allSatisfy { $0.media == nil })
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
      let batch = fixture.recording(for: [devices[0]])
      batch.start()
      await gate.waitUntilEntered()
      if shutdown { fixture.coordinator.beginShutdown() }
      let ending = Task { await batch.close() }
      await waitForObservedTestState { batch.phase == .cancelling }
      if !shutdown {
        try fixture.expectReserved(devices[0])
      } else {
        let rejected = await fixture.startRecording(for: [devices[1]])
        await waitForObservedTestState { rejected.isComplete }
        guard case .failed = rejected.items[0].state else { preconditionFailure("Shutdown must reject new work") }
        await rejected.close()
      }
      await gate.open()
      await ending.value
      let removed = await adb.removedRecordings
      precondition(batch.items.allSatisfy { $0.media == nil } && removed == [devices[0].id])
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
    let batch = await fixture.startRecording(for: devices)
    let stops = await adb.stops
    precondition(stops.isEmpty)
    await batch.beginFinalization(discarding: false).value
    precondition(batch.items.compactMap(\.media).map(\.device.id) == [devices[0].id])
    guard case .failed = batch.items[1].state else { preconditionFailure("Keep the failed target's item") }
    await batch.close()
  }

  static func finishAndCancelJoinCollection(root: URL, video: URL) async throws {
    let fixture = Fixture(root: root, video: video)
    let batch = await fixture.startRecording(for: [devices[0]])
    let gate = TestGate()
    await fixture.adb.blockDownload(on: gate)
    let first = batch.beginFinalization(discarding: false)
    await gate.waitUntilEntered()
    let finished = TestValue(false)
    let again = await startTestTask { await batch.beginFinalization(discarding: false).value; finished.value = true }
    let closed = TestValue(false)
    let close = await startTestTask { await batch.close(); closed.value = true }
    precondition(!finished.value && !closed.value)
    await gate.open()
    await first.value
    await again.value
    await close.value
    let removed = await fixture.adb.removedRecordings
    precondition(batch.items.compactMap(\.media).count == 1 && removed == [devices[0].id])
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
    let batch = fixture.recording(for: devices)
    batch.start()
    await gate.waitUntilEntered(2)
    devices[0].connection?.invalidate()
    await gate.open()
    _ = await batch.startup?.value
    await batch.beginFinalization(discarding: false).value
    guard case .failed = batch.items[0].state else { preconditionFailure("An old connection cannot rejoin") }
    precondition(batch.items.compactMap(\.media).map(\.device.id) == [devices[1].id])
    await batch.close()
    await fixture.coordinator.waitUntilIdle()
  }

}
