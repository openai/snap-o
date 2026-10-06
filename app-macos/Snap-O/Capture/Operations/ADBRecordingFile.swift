@preconcurrency import AVFoundation
import Dependencies
import Foundation

/// Android may write one frame with zero duration when the screen never changes.
enum ADBRecordingFile {
  static func restoreStaticDuration(at url: URL, recordedDuration: Duration) async throws {
    @Dependency(\.staticRecording)
    var io
    guard let frame = try await io.readFrame(url) else { return }
    let components = recordedDuration.components
    let seconds = Double(components.seconds) + Double(components.attoseconds) / 1e18
    guard seconds.isFinite, seconds > 0 else { return }

    let temporary = url.deletingLastPathComponent().appendingPathComponent("static-\(UUID().uuidString).mp4")
    defer { try? FileManager.default.removeItem(at: temporary) }
    try await io.writeFrame(frame, seconds, temporary)
    try Task.checkCancellation()
    _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
  }
}

/// The sample is read-only after creation; writing uses a retimed copy.
struct StaticRecordingFrame: @unchecked Sendable {
  let sample: CMSampleBuffer
  let transform: CGAffineTransform
}

struct StaticRecordingIO {
  var readFrame: @Sendable (URL) async throws -> StaticRecordingFrame?
  var writeFrame: @Sendable (StaticRecordingFrame, Double, URL) async throws -> Void
}

extension StaticRecordingIO: DependencyKey {
  static let liveValue = Self(readFrame: { url in
    let asset = AVURLAsset(url: url)
    guard let duration = try? await asset.load(.duration), duration == .zero,
          let track = try await asset.loadTracks(withMediaType: .video).first,
          let cursor = track.makeSampleCursorAtFirstSampleInDecodeOrder() else { return nil }
    let sample = try AVSampleBufferGenerator(asset: asset, timebase: nil)
      .makeSampleBuffer(for: AVSampleBufferRequest(start: cursor))
    guard cursor.stepInDecodeOrder(byCount: 1) == 0,
          CMSampleBufferGetNumSamples(sample) == 1,
          CMSampleBufferGetTotalSampleSize(sample) > 0 else { return nil }
    return try await StaticRecordingFrame(sample: sample, transform: track.load(.preferredTransform))
  }, writeFrame: { frame, seconds, destination in
    let writer = try AVAssetWriter(outputURL: destination, fileType: .mp4)
    let input = AVAssetWriterInput(
      mediaType: .video, outputSettings: nil, sourceFormatHint: CMSampleBufferGetFormatDescription(frame.sample)
    )
    input.transform = frame.transform
    writer.add(input)
    guard writer.startWriting() else { throw writer.error ?? StaticRecordingError("Could not finalize the static recording.") }
    writer.startSession(atSourceTime: .zero)
    var timing = CMSampleTimingInfo(
      duration: CMTime(seconds: seconds, preferredTimescale: 90000),
      presentationTimeStamp: .zero, decodeTimeStamp: .invalid
    )
    var retimed: CMSampleBuffer?
    let status = CMSampleBufferCreateCopyWithNewTiming(
      allocator: kCFAllocatorDefault, sampleBuffer: frame.sample, sampleTimingEntryCount: 1,
      sampleTimingArray: &timing, sampleBufferOut: &retimed
    )
    guard status == noErr, let retimed, input.append(retimed) else {
      writer.cancelWriting()
      throw writer.error ?? StaticRecordingError("Could not preserve the static recording frame.")
    }
    input.markAsFinished()
    writer.endSession(atSourceTime: timing.duration)
    await writer.finishWriting()
    guard writer.status == .completed else {
      throw writer.error ?? StaticRecordingError("Could not finalize the static recording.")
    }
  })
  static let testValue = Self(
    readFrame: unimplemented("StaticRecordingIO.readFrame"),
    writeFrame: unimplemented("StaticRecordingIO.writeFrame")
  )
}

extension DependencyValues {
  var staticRecording: StaticRecordingIO {
    get { self[StaticRecordingIO.self] }
    set { self[StaticRecordingIO.self] = newValue }
  }
}

private struct StaticRecordingError: LocalizedError {
  let errorDescription: String?
  init(_ message: String) {
    errorDescription = message
  }
}
