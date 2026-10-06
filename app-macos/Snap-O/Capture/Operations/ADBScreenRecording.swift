@preconcurrency import AVFoundation
import Foundation

final class ADBScreenRecording: ScreenRecording, @unchecked Sendable {
  let id = UUID()
  private let session: RecordingSession
  private let adb: ADBService

  init(session: RecordingSession, adb: ADBService) {
    self.session = session
    self.adb = adb
  }

  func stop() async throws {
    try await adb.exec().signalScreenrecordStop(session: session)
    try await session.waitUntilStopped(timeout: .seconds(5))
  }

  func waitUntilStopped() async throws {
    try await session.waitUntilStopped()
  }

  func save(to destination: URL) async throws {
    try await adb.exec().downloadScreenrecord(session: session, savingTo: destination)
    if let duration = try? await session.recordedDuration() {
      try await ADBRecordingFile.restoreStaticDuration(at: destination, recordedDuration: duration)
    }
  }

  func remove() async {
    try? await adb.exec().removeScreenrecord(session: session)
  }

  func close() async {
    session.close()
  }
}

/// Android may write one frame with zero duration when the screen never changes.
enum ADBRecordingFile {
  static func restoreStaticDuration(at url: URL, recordedDuration: Duration) async throws {
    let asset = AVURLAsset(url: url)
    guard let duration = try? await asset.load(.duration), duration == .zero,
          let track = try await asset.loadTracks(withMediaType: .video).first,
          let cursor = track.makeSampleCursorAtFirstSampleInDecodeOrder() else { return }
    let sample = try AVSampleBufferGenerator(asset: asset, timebase: nil)
      .makeSampleBuffer(for: AVSampleBufferRequest(start: cursor))
    guard cursor.stepInDecodeOrder(byCount: 1) == 0,
          CMSampleBufferGetNumSamples(sample) == 1,
          CMSampleBufferGetTotalSampleSize(sample) > 0 else { return }
    let components = recordedDuration.components
    let seconds = Double(components.seconds) + Double(components.attoseconds) / 1e18
    guard seconds.isFinite, seconds > 0 else { return }

    let temporary = url.deletingLastPathComponent().appendingPathComponent("static-\(UUID().uuidString).mp4")
    defer { try? FileManager.default.removeItem(at: temporary) }
    let writer = try AVAssetWriter(outputURL: temporary, fileType: .mp4)
    let input = AVAssetWriterInput(
      mediaType: .video, outputSettings: nil, sourceFormatHint: CMSampleBufferGetFormatDescription(sample)
    )
    input.transform = try await track.load(.preferredTransform)
    writer.add(input)
    guard writer.startWriting() else { throw writer.error ?? ADBError.protocolFailure("Could not finalize the static recording.") }
    writer.startSession(atSourceTime: .zero)
    var timing = CMSampleTimingInfo(
      duration: CMTime(seconds: seconds, preferredTimescale: 90_000),
      presentationTimeStamp: .zero, decodeTimeStamp: .invalid
    )
    var retimed: CMSampleBuffer?
    let status = CMSampleBufferCreateCopyWithNewTiming(
      allocator: kCFAllocatorDefault, sampleBuffer: sample, sampleTimingEntryCount: 1,
      sampleTimingArray: &timing, sampleBufferOut: &retimed
    )
    guard status == noErr, let retimed, input.append(retimed) else {
      writer.cancelWriting()
      throw writer.error ?? ADBError.protocolFailure("Could not preserve the static recording frame.")
    }
    input.markAsFinished()
    writer.endSession(atSourceTime: timing.duration)
    await writer.finishWriting()
    guard writer.status == .completed else {
      throw writer.error ?? ADBError.protocolFailure("Could not finalize the static recording.")
    }
    try Task.checkCancellation()
    _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
  }
}
