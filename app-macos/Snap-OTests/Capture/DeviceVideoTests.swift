import AppKit
@preconcurrency import AVFoundation
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
    let preview = try await coordinator.acquire(deviceIDs: ["synthetic"], for: .livePreview)
    let recording = try await coordinator.acquire(deviceIDs: ["synthetic"], for: .recording)
    await #expect(throws: (any Error).self) {
      try await coordinator.acquire(deviceIDs: ["synthetic"], for: .recording)
    }
    await coordinator.release(preview)
    let nextPreview = try await coordinator.acquire(deviceIDs: ["synthetic"], for: .livePreview)
    await coordinator.release(recording)
    await coordinator.release(nextPreview)
    await coordinator.waitUntilIdle()
  }

  @Test
  func captureCompatibilityAppliesInBothAcquisitionOrders() async throws {
    let activities: [DeviceCaptureActivity] = [.livePreview, .recording, .bugReportRecording]
    for existing in activities {
      for requested in activities {
        let coordinator = CaptureCoordinator()
        let first = try await coordinator.acquire(deviceIDs: ["shared"], for: existing)
        let independent = try await coordinator.acquire(deviceIDs: ["other"], for: requested)
        await coordinator.release(independent)
        switch (existing, requested) {
        case (.livePreview, .recording), (.recording, .livePreview):
          let second = try await coordinator.acquire(deviceIDs: ["shared"], for: requested)
          await coordinator.release(second)
        default:
          await #expect(throws: CaptureCoordinationError.deviceBusy(deviceID: "shared", activity: existing)) {
            try await coordinator.acquire(deviceIDs: ["other", "shared"], for: requested)
          }
          let unaffected = try await coordinator.acquire(deviceIDs: ["other"], for: requested)
          await coordinator.release(unaffected)
        }
        await coordinator.release(first)
        let next = try await coordinator.acquire(deviceIDs: ["shared"], for: requested)
        await coordinator.release(next)
        await coordinator.waitUntilIdle()
      }
    }
  }

  @Test
  func nativeRecordingPreservesSourceTimingAndRecoversOnDisconnect() async throws {
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
    let recording = NativeScreenRecording(deviceID: "synthetic")
    let stopped = Task { try await recording.waitUntilStopped() }
    var count = 0
    while let sample = output.copyNextSampleBuffer() {
      guard CMSampleBufferGetNumSamples(sample) > 0 else { continue }
      let format = try #require(CMSampleBufferGetFormatDescription(sample))
      if count == 0 { recording.receive(.format(format)) }
      recording.receive(.sample(sample, isKeyFrame: count == 0))
      count += 1
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(count == 3)
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
    #expect(duration >= 1.5 && duration < 2)
    await recording.close()
    #expect(!FileManager.default.fileExists(atPath: temporary.path), "Closing a recovered recording must remove its temporary file")
    #expect(FileManager.default.fileExists(atPath: saved.path))
  }

  @Test(.enabled(if: ProcessInfo.processInfo.environment["SNAPO_VIDEO_DEVICE_ID"] != nil))
  func physicalDeviceKeepsPreviewAndRecordingIndependent() async throws {
    let deviceID = try #require(ProcessInfo.processInfo.environment["SNAPO_VIDEO_DEVICE_ID"])
    let preview = DeviceVideoSource(deviceID: deviceID)
    let display = AVSampleBufferDisplayLayer()
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 160, height: 320),
      styleMask: [.borderless],
      backing: .buffered,
      defer: false
    )
    window.isReleasedWhenClosed = false
    let view = NSView(frame: NSRect(x: 0, y: 0, width: 160, height: 320))
    view.wantsLayer = true
    display.frame = view.bounds
    view.layer?.addSublayer(display)
    window.contentView = view
    window.orderFront(nil)
    defer { window.close() }
    var frames = 0
    var previewError: Error?
    preview.start { event in
      if case .sample(let sample, _) = event {
        display.sampleBufferRenderer.enqueue(sample)
        frames += 1
      }
      if case .stopped(let error) = event { previewError = error }
    }
    defer { preview.stop() }
    let recording = try await NativeScreenRecording.start(deviceID: deviceID)
    try await Task.sleep(for: .seconds(1))
    #expect(frames > 0)
    #expect(display.sampleBufferRenderer.displayedPixelBuffer() != nil)
    preview.stop()
    try await Task.sleep(for: .seconds(1))
    preview.start { event in
      if case .sample(let sample, _) = event {
        display.sampleBufferRenderer.enqueue(sample)
        frames += 1
      }
      if case .stopped(let error) = event { previewError = error }
    }
    try await Task.sleep(for: .seconds(1))
    try await recording.stop()
    let framesAtStop = frames
    try await Task.sleep(for: .seconds(2))
    let nextRecording = try await NativeScreenRecording.start(deviceID: deviceID)
    try await Task.sleep(for: .milliseconds(300))
    #expect(frames > framesAtStop)
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
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
    writer.add(input)
    #expect(writer.startWriting())
    writer.startSession(atSourceTime: .zero)
    var pixel: CVPixelBuffer?
    #expect(CVPixelBufferCreate(kCFAllocatorDefault, 32, 32, kCVPixelFormatType_32ARGB, nil, &pixel) == kCVReturnSuccess)
    let buffer = try #require(pixel)
    CVPixelBufferLockBaseAddress(buffer, [])
    memset(CVPixelBufferGetBaseAddress(buffer), 80, CVPixelBufferGetDataSize(buffer))
    CVPixelBufferUnlockBaseAddress(buffer, [])
    for timestamp in [0.0, 0.25, 1.5] {
      while !input.isReadyForMoreMediaData {
        try await Task.sleep(for: .milliseconds(1))
      }
      #expect(adaptor.append(buffer, withPresentationTime: CMTime(seconds: timestamp, preferredTimescale: 600)))
    }
    input.markAsFinished()
    await writer.finishWriting()
    #expect(writer.status == .completed)
  }
}
