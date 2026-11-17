import AVFoundation
import Foundation
import Testing

@MainActor
struct NativeRecordingMediaTests {
  @Test
  func encodesRGBAFramesToPlayableH264() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
    defer { try? FileManager.default.removeItem(at: url) }
    let builder = EmulatorPreviewFrameBuilder()
    let pixels = Data(Array(repeating: [UInt8(255), 0, 0, 255], count: 32 * 32).flatMap(\.self))
    let origin: UInt64 = 3_200_000_000_000
    let sample = try #require(try builder.makeSample(rgba: pixels, width: 32, height: 32, timestamp: origin))
    let format = try #require(CMSampleBufferGetFormatDescription(sample))
    let writer = try AVRecordingWriter(url: url, format: format, start: CMTime(value: Int64(origin), timescale: 1_000_000))
    try writer.append(sample)
    for offset: UInt64 in [33333, 1_500_000, 1_500_001] {
      while !writer.isReadyForMoreMediaData {
        await Task.yield()
      }
      let next = try #require(try builder.makeSample(rgba: pixels, width: 32, height: 32, timestamp: origin + offset))
      try writer.append(next)
    }
    try await writer.finish(at: CMTime(value: Int64(origin + 2_000_000), timescale: 1_000_000))
    #expect(writer.isComplete)
    let asset = AVURLAsset(url: url)
    let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
    let encoded = try #require(try await track.load(.formatDescriptions).first)
    #expect(CMFormatDescriptionGetMediaSubType(encoded) == kCMVideoCodecType_H264)
    let duration = try await asset.load(.duration)
    #expect(abs(duration.seconds - 2) < 0.01)
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(
      track: track,
      outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
    )
    reader.add(output)
    try #require(reader.startReading())
    let decoded = try #require(output.copyNextSampleBuffer())
    var timestamps = [CMSampleBufferGetPresentationTimeStamp(decoded).seconds]
    while let next = output.copyNextSampleBuffer() {
      timestamps.append(CMSampleBufferGetPresentationTimeStamp(next).seconds)
    }
    #expect(timestamps.count == 4)
    #expect(zip(timestamps, timestamps.dropFirst()).allSatisfy { $0 < $1 })
    let image = try #require(CMSampleBufferGetImageBuffer(decoded))
    CVPixelBufferLockBaseAddress(image, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(image, .readOnly) }
    let bytes = try #require(CVPixelBufferGetBaseAddress(image)).assumingMemoryBound(to: UInt8.self)
    #expect(bytes[0] < 10)
    #expect(bytes[1] < 10)
    #expect(bytes[2] > 245)
  }

  @Test
  func holdsTheLastEncodedVideoFrameUntilStop() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
    defer { try? FileManager.default.removeItem(at: url) }
    // One solid-red 16 × 16 H.264 keyframe, including its parameter sets.
    let data = try #require(Data(base64Encoded: "AAAAAWdCwArZHsBEAAADAAQAAAMACDxImSAAAAABaMuDyyAAAAABZYiEBXxGKAALjMcAAToY4AA2DYA="))
    var builder = DeviceVideoSampleBuilder()
    let first = try #require(try builder.sample(data: data, timestamp: 0, flags: 1))
    let writer = try AVRecordingWriter(url: url, format: #require(builder.format), start: .zero)
    try writer.append(first)
    while !writer.isReadyForMoreMediaData {
      await Task.yield()
    }
    let last = try #require(try builder.sample(data: data, timestamp: 100_000, flags: 1))
    try writer.append(last)
    let stop = CMTime(value: 3, timescale: 1)
    try await writer.finish(at: stop)

    let track = try #require(try await AVURLAsset(url: url).loadTracks(withMediaType: .video).first)
    let frame = try #require(track.makeSampleCursorAtLastSampleInDecodeOrder())
    #expect(frame.presentationTimeStamp + frame.currentSampleDuration == stop)
  }
}
