@preconcurrency import AVFoundation
import Foundation

@main
@MainActor
struct RecordingTests {
  static let devices = ["Device A", "Device B"].map {
    Device(id: $0, model: $0, androidVersion: "16", vendorModel: nil, manufacturer: nil, avdName: nil)
  }

  static let options = RecordingOptions(recordsBugReport: false, showsTouches: false)

  static func main() async throws {
    let watchdog = Task {
      try await Task.sleep(for: .seconds(30))
      fatalError("Recording tests timed out")
    }
    defer { watchdog.cancel() }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let video = root.appendingPathComponent("fixture.mp4")
    try await makeVideo(at: video)
    try await failedDeviceLeavesHealthyRecordingActive(root: root, video: video)
    try await collectionFailurePreservesHealthyRecording(root: root, video: video)
    try await disconnectedDeviceLeavesHealthyRecordingActive(root: root, video: video)
    try await cancellationDoesNotSignalEndedSession(root: root, video: video)
    try await endedSessionRestoresTouchIndicators(root: root, video: video)
    try await unconfirmedStopPreservesRemoteRecording(root: root, video: video)
    try await invalidDownloadPreservesRemoteRecording(root: root)
    try await confirmedRecordingRemovesRemoteCopy(root: root, video: video)
    try await bugReportRecordingIsExclusive(root: root, video: video)
    print("Recording tests passed (9 cases)")
  }

  struct Fixture {
    let adb: ADBService
    let history: CaptureHistoryRepository
    let service: RecordingService

    init(root: URL, video: URL) {
      let directory = root.appendingPathComponent(UUID().uuidString)
      adb = ADBService(video: video)
      history = CaptureHistoryRepository(root: directory.appendingPathComponent("history"))
      service = RecordingService(
        adb: adb, fileStore: FileStore(baseDir: directory.appendingPathComponent("preview")),
        coordinator: CaptureCoordinator(), history: history
      )
    }

    func waitForFailure() async {
      await RecordingTests.eventually {
        await history.currentSnapshot().entries.first?.items.first?.failure != nil
      }
    }
  }

  static func bugReportRecordingIsExclusive(root: URL, video: URL) async throws {
    let coordinator = CaptureCoordinator()
    let adb = ADBService(video: video)
    let service = RecordingService(adb: adb, fileStore: FileStore(baseDir: root), coordinator: coordinator)
    let preview = try await coordinator.acquire(deviceIDs: [devices[0].id], for: .livePreview)
    do {
      _ = try await service.start(for: devices, options: RecordingOptions(recordsBugReport: true, showsTouches: false))
      fatalError("Another window's preview must block bug-report recording")
    } catch let error as CaptureCoordinationError {
      precondition(error == .deviceBusy(deviceID: devices[0].id, activity: .livePreview))
    }
    let settings = await adb.touchSettings
    precondition(settings.isEmpty, "Acquire exclusive access before changing device settings")
    await coordinator.release(preview)
    let recording = try await service.start(for: devices, options: RecordingOptions(recordsBugReport: true, showsTouches: false))
    do {
      _ = try await coordinator.acquire(deviceIDs: [devices[0].id], for: .livePreview)
      fatalError("An active bug-report recording must block another window's preview")
    } catch let error as CaptureCoordinationError {
      precondition(error == .deviceBusy(deviceID: devices[0].id, activity: .bugReportRecording))
    }
    await service.cancel(recording)
    let resumed = try await coordinator.acquire(deviceIDs: [devices[0].id], for: .livePreview)
    await coordinator.release(resumed)
    await service.shutdown()
  }

  static func failedDeviceLeavesHealthyRecordingActive(root: URL, video: URL) async throws {
    let fixture = Fixture(root: root, video: video)
    let handle = try await fixture.service.start(for: devices, options: options)
    await fixture.adb.endUnexpectedly(devices[0].id)
    await fixture.waitForFailure()
    let stops = await fixture.adb.stops
    precondition(stops.isEmpty, "A device failure must not stop healthy recordings")
    await fixture.service.cancel(handle)
  }

  static func collectionFailurePreservesHealthyRecording(root: URL, video: URL) async throws {
    let fixture = Fixture(root: root, video: video)
    let handle = try await fixture.service.start(for: devices, options: options)
    await fixture.adb.failCollection(devices[0].id)

    await fixture.service.finish(handle)
    guard let result = await fixture.service.waitForCompletion(of: handle) else {
      fatalError("Stop must return the collected recordings")
    }
    let media = result.media
    precondition(media.map(\.device.id) == [devices[1].id], "The healthy recording must survive the failed collection")
    let savedURL = media[0].media.url!
    precondition(FileManager.default.fileExists(atPath: savedURL.path), "The result must include the saved video")
  }

  static func disconnectedDeviceLeavesHealthyRecordingActive(root: URL, video: URL) async throws {
    let fixture = Fixture(root: root, video: video)
    let handle = try await fixture.service.start(for: devices, options: options)
    await fixture.service.updateConnectedDeviceIDs([devices[1].id], for: handle)
    let stops = await fixture.adb.stops
    precondition(stops.isEmpty, "Disconnect must leave the other recording active")
    await fixture.service.cancel(handle)
  }

  static func cancellationDoesNotSignalEndedSession(root: URL, video: URL) async throws {
    let fixture = Fixture(root: root, video: video)
    let handle = try await fixture.service.start(for: devices, options: options)
    await fixture.adb.endUnexpectedly(devices[0].id)
    await fixture.waitForFailure()

    await fixture.service.cancel(handle)
    let stops = await fixture.adb.stops
    precondition(stops == [devices[1].id], "Only the active recording may receive a stop signal")
  }

  static func endedSessionRestoresTouchIndicators(root: URL, video: URL) async throws {
    let fixture = Fixture(root: root, video: video)
    let handle = try await fixture.service.start(
      for: devices, options: RecordingOptions(recordsBugReport: false, showsTouches: true)
    )
    await fixture.adb.endUnexpectedly(devices[0].id)
    await fixture.waitForFailure()

    let settings = await fixture.adb.touchSettings
    precondition(settings == [devices[0].id: false, devices[1].id: true], "Restore only the ended device's setting")
    await fixture.service.cancel(handle)
  }

  static func unconfirmedStopPreservesRemoteRecording(root: URL, video: URL) async throws {
    let fixture = Fixture(root: root, video: video)
    let handle = try await fixture.service.start(for: [devices[0]], options: options)
    await fixture.adb.failStop(devices[0].id)
    await fixture.service.finish(handle)

    let removed = await fixture.adb.removedRecordings
    precondition(removed.isEmpty, "An unconfirmed stop must preserve the device copy")
  }

  static func invalidDownloadPreservesRemoteRecording(root: URL) async throws {
    let invalidVideo = root.appendingPathComponent("incomplete.mp4")
    try Data("incomplete recording".utf8).write(to: invalidVideo)
    let fixture = Fixture(root: root, video: invalidVideo)
    let handle = try await fixture.service.start(for: [devices[0]], options: options)
    await fixture.service.finish(handle)

    let removed = await fixture.adb.removedRecordings
    precondition(removed.isEmpty, "An unusable download must preserve the device copy")
  }

  static func confirmedRecordingRemovesRemoteCopy(root: URL, video: URL) async throws {
    let fixture = Fixture(root: root, video: video)
    let handle = try await fixture.service.start(for: [devices[0]], options: options)
    await fixture.service.finish(handle)

    let removed = await fixture.adb.removedRecordings
    precondition(removed == [devices[0].id], "A confirmed stop and usable local copy allow remote cleanup")
  }

  static func eventually(_ condition: () async -> Bool) async {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while ContinuousClock.now < deadline {
      if await condition() { return }
      await Task.yield()
    }
    fatalError("Expected recording state was not reached")
  }

  static func makeVideo(at url: URL) async throws {
    let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
      AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 16, AVVideoHeightKey: 16
    ])
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
    writer.add(input)
    precondition(writer.startWriting())
    writer.startSession(atSourceTime: .zero)
    var buffer: CVPixelBuffer?
    precondition(CVPixelBufferCreate(kCFAllocatorDefault, 16, 16, kCVPixelFormatType_32ARGB, nil, &buffer) == kCVReturnSuccess)
    let frame = buffer!
    CVPixelBufferLockBaseAddress(frame, [])
    memset(CVPixelBufferGetBaseAddress(frame)!, 0, CVPixelBufferGetDataSize(frame))
    CVPixelBufferUnlockBaseAddress(frame, [])
    await eventually { input.isReadyForMoreMediaData }
    precondition(adaptor.append(frame, withPresentationTime: .zero))
    await eventually { input.isReadyForMoreMediaData }
    precondition(adaptor.append(frame, withPresentationTime: CMTime(value: 1, timescale: 1)))
    input.markAsFinished()
    await writer.finishWriting()
    precondition(writer.status == .completed)
  }
}
