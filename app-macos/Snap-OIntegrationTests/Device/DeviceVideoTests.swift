@preconcurrency import AVFoundation
import Clocks
import Dependencies
import DependenciesTestSupport
import Foundation
@testable import Snap_O
import Testing

@Suite(.serialized)
@MainActor
struct DeviceVideoTests {
  @Test
  func validatesDeviceVideoVersion() throws {
    try DeviceVideoPacket.validateHeader(Data([0x53, 0x4E, 0x56, 0x31]))
    #expect(throws: (any Error).self) { try DeviceVideoPacket.validateHeader(Data([0x53, 0x4E, 0x56, 0x32])) }
    #expect(throws: (any Error).self) { try DeviceVideoPacket.validateHeader(Data([0x53, 0x4E, 0x56])) }
  }

  @Test
  func rejectsOversizedPacketsBeforeReadingTheirPayload() throws {
    var bytes = Data([2, 0, 0, 0, 1])
    bytes.append(contentsOf: [UInt8](repeating: 0, count: 8))
    bytes.append(contentsOf: [1, 0, 0, 1])
    var offset = 0
    #expect(throws: (any Error).self) {
      try DeviceVideoPacket.read { count in
        guard offset + count <= bytes.count else { throw CocoaError(.fileReadCorruptFile) }
        defer { offset += count }
        return bytes.subdata(in: offset ..< offset + count)
      }
    }
    #expect(offset == 17)
  }

  @Test
  func splitsMixedStartCodesWithoutInventingFrames() throws {
    let units = try DeviceVideoSampleBuilder.nalUnits(Data([0, 0, 0, 1, 0x67, 5, 0, 0, 1, 0x68, 7]))
    #expect(units == [Data([0x67, 5]), Data([0x68, 7])])
    #expect(throws: (any Error).self) { try DeviceVideoSampleBuilder.nalUnits(Data([0, 0, 1])) }
  }

  @Test
  func previewAndRecordingLeasesAreIndependent() async throws {
    let coordinator = CaptureCoordinator()
    let target = DeviceTarget(serial: "synthetic", transportID: "1")
    let preview = try coordinator.acquire(target: target, for: .livePreview)
    let otherPreview = try coordinator.acquire(target: target, for: .livePreview)
    let recording = try coordinator.acquire(target: target, for: .recording)
    let otherRecording = try coordinator.acquire(
      target: DeviceTarget(serial: "another-device", transportID: "2"), for: .recording
    )
    coordinator.release(preview)
    coordinator.release(recording)
    let screenshot = try coordinator.acquire(target: target, for: .screenshot)
    coordinator.release(otherPreview)
    coordinator.release(screenshot)
    coordinator.release(otherRecording)
    await coordinator.waitUntilIdle()
  }

  @Test
  func captureCompatibilityAppliesInBothAcquisitionOrders() async throws {
    let activities: [DeviceCaptureActivity] = [.screenshot, .livePreview, .recording, .bugReportRecording]
    for serial in ["phone", "emulator-5554"] {
      for existing in activities {
        for requested in activities {
          for overlaps in [false, true] {
            let coordinator = CaptureCoordinator()
            let target = DeviceTarget(serial: serial, transportID: "1")
            let nextTarget = overlaps ? target : DeviceTarget(serial: serial, transportID: "2")
            let first = try coordinator.acquire(target: target, for: existing)
            let conflicts = overlaps && (
              existing == .bugReportRecording || requested == .bugReportRecording
                || (serial.hasPrefix("emulator-") && existing == .recording && requested == .recording)
            )
            if conflicts {
              #expect(throws: CaptureCoordinationError.deviceBusy(deviceID: serial, activity: existing)) {
                try coordinator.acquire(target: nextTarget, for: requested)
              }
            } else {
              let second = try coordinator.acquire(target: nextTarget, for: requested)
              coordinator.release(second)
            }
            coordinator.release(first)
            let next = try coordinator.acquire(target: nextTarget, for: requested)
            coordinator.release(next)
            await coordinator.waitUntilIdle()
          }
        }
      }
    }
  }

  @Test(.dependency(\.continuousClock, TestClock()), arguments: [0.0, 0.25, 3.0])
  func nativeRecordingPreservesSourceTimingAndRecoversOnDisconnect(tail: Double) async throws {
    @Dependency(\.continuousClock, as: TestClock<Duration>.self)
    var clock
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appendingPathComponent("source.mp4")
    try await Self.makeVideo(at: source)
    let asset = AVURLAsset(url: source)
    let track = try #require(await asset.loadTracks(withMediaType: .video).first)
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
    reader.add(output)
    #expect(reader.startReading())
    let recording = NativeScreenRecording(target: DeviceTarget(serial: "synthetic", transportID: "1"))
    let stopped = Task { try await recording.waitUntilStopped() }
    var count = 0
    while let sample = output.copyNextSampleBuffer() {
      guard CMSampleBufferGetNumSamples(sample) > 0 else { continue }
      let format = try #require(CMSampleBufferGetFormatDescription(sample))
      if count == 0 { recording.receive(.format(format)) }
      recording.receive(.sample(sample, isKeyFrame: count == 0))
      count += 1
    }
    #expect(count == 3)
    await clock.advance(by: .seconds(tail))
    recording.receive(.stopped(CocoaError(.fileReadUnknown)))
    await #expect(throws: (any Error).self) { try await stopped.value }
    await #expect(throws: (any Error).self) { try await recording.waitUntilStopped() }
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("snapo-recording-\(recording.id).mp4")
    await #expect(throws: (any Error).self) { try await recording.save(to: source) }
    await recording.close()
    #expect(FileManager.default.fileExists(atPath: temporary.path), "A failed save must preserve the recovery file")
    let saved = directory.appendingPathComponent("saved.mp4")
    try await recording.save(to: saved)
    let result = AVURLAsset(url: saved)
    #expect(try await result.load(.isPlayable))
    let duration = try await result.load(.duration).seconds
    #expect(abs(duration - (1.5 + max(1.0 / 60, tail))) < 0.001)
    await recording.close()
    #expect(!FileManager.default.fileExists(atPath: temporary.path), "Closing a recovered recording must remove its temporary file")
    #expect(FileManager.default.fileExists(atPath: saved.path))
  }

  @Test(
    .enabled(if: ProcessInfo.processInfo.environment["SNAPO_VIDEO_DEVICE_ID"] != nil),
    .timeLimit(.minutes(1)),
    .dependency(\.continuousClock, ContinuousClock())
  )
  func physicalDeviceKeepsPreviewAndRecordingIndependent() async throws {
    let deviceID = try #require(ProcessInfo.processInfo.environment["SNAPO_VIDEO_DEVICE_ID"])
    let tracker = DeviceTracker(adbService: ADBService())
    await tracker.startTracking()
    let devices = await tracker.previewDeviceStream()
    var selected: DeviceTarget?
    for await snapshot in devices {
      if let device = snapshot.first(where: { $0.id == deviceID }) {
        selected = try device.requireConnection()
        break
      }
    }
    let target = try #require(selected)
    defer { Task { await tracker.stopTracking() } }
    var preview = DeviceVideoSource(target: target)
    let frames = TestValue(0)
    let previewStopped = TestValue(false)
    var previewError: Error?
    preview.start { event in
      if case .sample = event { frames.value += 1 }
      if case .stopped(let error) = event { previewError = error
        previewStopped.value = true
      }
    }
    defer { preview.stop() }
    try await waitForState { frames.value > 0 || previewStopped.value }
    try #require(!previewStopped.value)
    // Let an unchanged screen become idle before another consumer joins.
    try await ContinuousClock().sleep(for: .seconds(3))
    let recording = try await NativeScreenRecording.start(target: target)
    let framesBeforeRejoining = frames.value
    preview.stop()
    await preview.waitUntilStopped()
    preview = DeviceVideoSource(target: target)
    preview.start { event in
      if case .sample = event { frames.value += 1 }
      if case .stopped(let error) = event { previewError = error
        previewStopped.value = true
      }
    }
    try await waitForState { frames.value > framesBeforeRejoining || previewStopped.value }
    try #require(!previewStopped.value)
    // Record a static interval without requiring new frames.
    try await ContinuousClock().sleep(for: .seconds(2))
    try await recording.stop()
    let framesAtStop = frames.value
    let nextRecording = try await NativeScreenRecording.start(target: target)
    try await waitForState { frames.value > framesAtStop || previewStopped.value }
    #expect(frames.value > framesAtStop)
    try await nextRecording.stop()
    await nextRecording.remove()
    #expect(previewError == nil)
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("video-test-\(UUID()).mp4")
    defer { try? FileManager.default.removeItem(at: url) }
    try await recording.save(to: url)
    let asset = AVURLAsset(url: url)
    #expect(try await asset.load(.isPlayable))
    #expect(try await asset.load(.duration).seconds >= 2)
    await recording.remove()
  }

  private static func makeVideo(at url: URL) async throws {
    let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
      AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 32, AVVideoHeightKey: 32,
      AVVideoCompressionPropertiesKey: [AVVideoAllowFrameReorderingKey: false]
    ])
    let receiver = writer.inputPixelBufferReceiver(for: input, pixelBufferAttributes: nil)
    #expect(writer.startWriting())
    writer.startSession(atSourceTime: .zero)
    let buffer = try CVMutablePixelBuffer(.init(
      pixelFormatType: .init(rawValue: kCVPixelFormatType_32ARGB), size: .init(width: 32, height: 32)
    ))
    buffer.withUnsafeBuffer { pixel in
      CVPixelBufferLockBaseAddress(pixel, [])
      memset(CVPixelBufferGetBaseAddress(pixel), 80, CVPixelBufferGetDataSize(pixel))
      CVPixelBufferUnlockBaseAddress(pixel, [])
    }
    let pixels = CVReadOnlyPixelBuffer(buffer)
    for timestamp in [0.0, 0.25, 1.5] {
      try await receiver.append(pixels, with: CMTime(seconds: timestamp, preferredTimescale: 600))
    }
    receiver.finish()
    await writer.finishWriting()
    #expect(writer.status == .completed)
  }
}
