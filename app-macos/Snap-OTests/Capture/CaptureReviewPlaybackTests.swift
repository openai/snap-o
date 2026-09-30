@preconcurrency import AVFoundation
@testable import Snap_O
import Testing

struct CaptureReviewPlaybackTests {
  @Test(arguments: [(0.0, "00:00"), (61.9, "01:01"), (3661.0, "1:01:01"), (Double.nan, "00:00")])
  @MainActor
  func formatsTimestamp(input: (Double, String)) {
    #expect(CaptureReviewPlayback.timestamp(input.0) == input.1)
  }

  @Test
  func playbackControlsStayWithinPane() {
    for size in [CGSize(width: 260, height: 500), CGSize(width: 400, height: 800), CGSize(width: 800, height: 400)] {
      for ratio: CGFloat in [0.5, 1, 2] {
        let video = CaptureReviewLayout.mediaFrame(in: size, aspectRatio: ratio, showsPlayback: true)
        let controls = CaptureReviewLayout.playbackFrame(in: size, mediaFrame: video)
        #expect(controls.maxY <= size.height - CaptureReviewLayout.edgeSpacing + 0.0001)
        #expect(controls.minX >= CaptureReviewLayout.edgeSpacing)
        #expect(controls.maxX <= size.width - CaptureReviewLayout.edgeSpacing)
      }
    }
  }

  @Test @MainActor
  func scrubbingPreservesPauseChoice() {
    let playback = CaptureReviewPlayback()
    playback.togglePlayback()
    playback.setScrubbing(true)
    playback.setScrubbing(false)
    #expect(!playback.wantsPlayback)
  }

  @Test @MainActor
  func visibilityChangesPreservePauseChoice() {
    let playback = CaptureReviewPlayback()
    playback.togglePlayback()
    playback.setWindowVisible(false)
    playback.setWindowVisible(true)
    #expect(!playback.wantsPlayback)
  }

  @Test @MainActor
  func scrubbingPreservesPlaybackSpeed() {
    let playback = CaptureReviewPlayback()
    playback.setSpeed(0.5)
    playback.setScrubbing(true)
    playback.setScrubbing(false)
    #expect(playback.speed == 0.5)
  }

  @Test @MainActor
  func rapidScrubbingSettlesOnExactFinalPosition() async throws {
    let source = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mp4")
    defer { try? FileManager.default.removeItem(at: source) }
    try await makeVideo(at: source)
    let playback = CaptureReviewPlayback()
    defer { playback.stop() }
    await playback.load(source)
    playback.togglePlayback()
    playback.setScrubbing(true)
    for index in 0 ..< 200 {
      playback.seek(to: Double(index % 9) / 10)
    }
    playback.seek(to: 0.4)
    playback.setScrubbing(false)
    let deadline = ContinuousClock.now + .seconds(5)
    while abs(playback.player.currentTime().seconds - 0.4) > 0.001, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(abs(playback.player.currentTime().seconds - 0.4) < 0.001)
  }

  private func makeVideo(at url: URL) async throws {
    let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
      AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 32, AVVideoHeightKey: 32,
      AVVideoCompressionPropertiesKey: [AVVideoAllowFrameReorderingKey: false]
    ])
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
    writer.add(input)
    try #require(writer.startWriting())
    writer.startSession(atSourceTime: .zero)
    var pixel: CVPixelBuffer?
    try #require(CVPixelBufferCreate(kCFAllocatorDefault, 32, 32, kCVPixelFormatType_32ARGB, nil, &pixel) == kCVReturnSuccess)
    let buffer = try #require(pixel)
    CVPixelBufferLockBaseAddress(buffer, [])
    memset(CVPixelBufferGetBaseAddress(buffer), 80, CVPixelBufferGetDataSize(buffer))
    CVPixelBufferUnlockBaseAddress(buffer, [])
    for index in 0 ..< 10 {
      while !input.isReadyForMoreMediaData {
        try await Task.sleep(for: .milliseconds(1))
      }
      try #require(adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(index), timescale: 10)))
    }
    writer.endSession(atSourceTime: CMTime(value: 1, timescale: 1))
    input.markAsFinished()
    await writer.finishWriting()
    try #require(writer.status == .completed)
  }
}
