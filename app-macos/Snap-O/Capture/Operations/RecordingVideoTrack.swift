@preconcurrency import AVFoundation
import Dependencies

@MainActor
struct RecordingVideoTrack {
  private var format: CMVideoFormatDescription?
  private var lastFrame: (timestamp: CMTime, receivedAt: AnyClock<Duration>.Instant)?

  mutating func sample(for event: LivePreviewFrameEvent) throws -> (CMSampleBuffer, CMVideoFormatDescription)? {
    switch event {
    case .format(let incoming, _):
      if lastFrame != nil, let format, !CMFormatDescriptionEqual(format, otherFormatDescription: incoming) {
        throw ADBError.protocolFailure("Recording ended because the device video format changed")
      }
      format = incoming
    case .sample(let sample, let keyFrame):
      guard let format, keyFrame || lastFrame != nil else { return nil }
      return (sample, format)
    case .stopped(let error):
      throw error ?? ADBError.protocolFailure("Device video ended unexpectedly")
    case .density: break
    }
    return nil
  }

  mutating func append(_ sample: CMSampleBuffer, to writer: any NativeRecordingWriter, clock: AnyClock<Duration>) throws {
    try writer.append(sample)
    lastFrame = (CMSampleBufferGetPresentationTimeStamp(sample), clock.now)
  }

  func endTime(at stop: AnyClock<Duration>.Instant) -> CMTime? {
    guard let lastFrame else { return nil }
    // An idle screen can stop sending frames. Hold the last one until recording stops.
    let elapsed = lastFrame.receivedAt.duration(to: stop).components
    let tail = max(1.0 / 60, Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18)
    return lastFrame.timestamp + CMTime(seconds: tail, preferredTimescale: 1_000_000)
  }
}
