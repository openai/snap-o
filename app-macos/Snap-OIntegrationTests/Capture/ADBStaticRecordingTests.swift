@preconcurrency import AVFoundation
import Foundation
@testable import Snap_O
import Testing

struct ADBStaticRecordingTests {
  @Test
  func restoresStaticDurationWithoutChangingTheFrame() async throws {
    let fixture = try await makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let original = try await firstSample(at: fixture.staticVideo)
    #expect(try await AVURLAsset(url: fixture.staticVideo).load(.duration) == .zero)

    try await ADBRecordingFile.restoreStaticDuration(at: fixture.staticVideo, recordedDuration: .seconds(5))

    let asset = AVURLAsset(url: fixture.staticVideo)
    #expect(try await asset.load(.isPlayable))
    #expect(try await asset.load(.duration).seconds == 5)
    let repaired = try await firstSample(at: fixture.staticVideo)
    #expect(try sampleBytes(repaired) == sampleBytes(original))
    let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
    #expect(try await track.load(.preferredTransform) == fixture.transform)
    #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).count == 2)
  }

  @Test
  func leavesNormalRecordingsUnchanged() async throws {
    let fixture = try await makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let original = try Data(contentsOf: fixture.normalVideo)

    try await ADBRecordingFile.restoreStaticDuration(at: fixture.normalVideo, recordedDuration: .seconds(5))

    #expect(try Data(contentsOf: fixture.normalVideo) == original)
  }

  @Test
  func cancellationPreservesTheSourceAndRemovesTheTemporaryFile() async throws {
    let fixture = try await makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let original = try Data(contentsOf: fixture.staticVideo)
    let task = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      try await ADBRecordingFile.restoreStaticDuration(at: fixture.staticVideo, recordedDuration: .seconds(5))
    }
    await #expect(throws: (any Error).self) { try await task.value }
    #expect(try Data(contentsOf: fixture.staticVideo) == original)
    #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).count == 2)
  }

  private struct Fixture {
    let root: URL
    let normalVideo: URL
    let staticVideo: URL
    let transform = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 0, ty: 0)
  }

  private func makeFixture() async throws -> Fixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let fixture = Fixture(
      root: root, normalVideo: root.appendingPathComponent("normal.mp4"), staticVideo: root.appendingPathComponent("static.mp4")
    )
    do {
      let writer = try AVAssetWriter(outputURL: fixture.normalVideo, fileType: .mp4)
      let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 32, AVVideoHeightKey: 32
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
      try await receiver.append(CVReadOnlyPixelBuffer(buffer), with: .zero)
      input.markAsFinished()
      writer.endSession(atSourceTime: CMTime(seconds: 1, preferredTimescale: 600))
      await writer.finishWriting()
      try #require(writer.status == .completed)

      let sample = try await firstSample(at: fixture.normalVideo)
      let staticWriter = try AVAssetWriter(outputURL: fixture.staticVideo, fileType: .mp4)
      let staticInput = AVAssetWriterInput(
        mediaType: .video, outputSettings: nil, sourceFormatHint: CMSampleBufferGetFormatDescription(sample)
      )
      staticInput.transform = fixture.transform
      staticWriter.add(staticInput)
      try #require(staticWriter.startWriting())
      staticWriter.startSession(atSourceTime: .zero)
      var timing = CMSampleTimingInfo(duration: .zero, presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
      var retimed: CMSampleBuffer?
      try #require(CMSampleBufferCreateCopyWithNewTiming(
        allocator: kCFAllocatorDefault, sampleBuffer: sample, sampleTimingEntryCount: 1,
        sampleTimingArray: &timing, sampleBufferOut: &retimed
      ) == noErr)
      try #require(staticInput.append(try #require(retimed)))
      staticInput.markAsFinished()
      staticWriter.endSession(atSourceTime: .zero)
      await staticWriter.finishWriting()
      try #require(staticWriter.status == .completed)
      return fixture
    } catch {
      try? FileManager.default.removeItem(at: root)
      throw error
    }
  }

  private func firstSample(at url: URL) async throws -> CMSampleBuffer {
    let asset = AVURLAsset(url: url)
    let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
    let cursor = try #require(track.makeSampleCursorAtFirstSampleInDecodeOrder())
    return try AVSampleBufferGenerator(asset: asset, timebase: nil).makeSampleBuffer(for: AVSampleBufferRequest(start: cursor))
  }

  private func sampleBytes(_ sample: CMSampleBuffer) throws -> Data {
    let buffer = try #require(CMSampleBufferGetDataBuffer(sample))
    var bytes = Data(count: CMBlockBufferGetDataLength(buffer))
    let result = bytes.withUnsafeMutableBytes { bytes in
      guard let address = bytes.baseAddress else { return OSStatus(-1) }
      return CMBlockBufferCopyDataBytes(buffer, atOffset: 0, dataLength: bytes.count, destination: address)
    }
    try #require(result == noErr)
    return bytes
  }
}
