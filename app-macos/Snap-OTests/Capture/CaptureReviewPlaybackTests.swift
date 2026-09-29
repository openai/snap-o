@preconcurrency import AVFoundation
@testable import Snap_O
import Testing

struct CaptureReviewPlaybackTests {
  @Test @MainActor
  func timestampsRemainCompact() {
    #expect(CaptureReviewPlayback.timestamp(0) == "00:00")
    #expect(CaptureReviewPlayback.timestamp(61.9) == "01:01")
    #expect(CaptureReviewPlayback.timestamp(3661) == "1:01:01")
    #expect(CaptureReviewPlayback.timestamp(.nan) == "00:00")
  }

  @Test
  func controlsFitBelowVideoWithoutChangingItsAspectRatio() {
    for size in [CGSize(width: 260, height: 500), CGSize(width: 400, height: 800), CGSize(width: 800, height: 400)] {
      for ratio: CGFloat in [0.5, 1, 2] {
        let video = CaptureReviewLayout.mediaFrame(in: size, aspectRatio: ratio, showsPlayback: true)
        let controls = CaptureReviewLayout.playbackFrame(in: size, mediaFrame: video)
        #expect(abs(video.width / video.height - ratio) < 0.0001)
        #expect(controls.height == 28)
        #expect(controls.minY - video.maxY == 12)
        #expect(controls.maxY <= size.height - CaptureReviewLayout.edgeSpacing + 0.0001)
        #expect(controls.minX >= CaptureReviewLayout.edgeSpacing)
        #expect(controls.maxX <= size.width - CaptureReviewLayout.edgeSpacing)
        #expect(controls.midX == video.midX)
      }
    }
  }

  @Test @MainActor
  func playbackPreservesPauseSpeedAndScrubbingChoices() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("video.mp4")
    try await makeVideo(at: source)
    let playback = CaptureReviewPlayback()
    defer { playback.stop() }
    playback.setWindowVisible(true)
    await playback.load(source)
    #expect(playback.duration >= 1)
    #expect(playback.isPlaying)
    playback.setSpeed(0.5)
    playback.setScrubbing(true)
    #expect(!playback.isPlaying)
    playback.seek(to: 0.5)
    #expect(playback.time == 0.5)
    playback.setScrubbing(false)
    #expect(playback.isPlaying && playback.speed == 0.5)
    playback.togglePlayback()
    playback.setWindowVisible(false)
    playback.setWindowVisible(true)
    #expect(!playback.isPlaying && !playback.wantsPlayback)
    playback.setScrubbing(true)
    playback.seek(to: -1)
    #expect(playback.time == 0)
    playback.setScrubbing(false)
    #expect(!playback.isPlaying)
    playback.stepFrame(1)
    #expect(playback.time > 0 && playback.time < 0.2)
    playback.seek(to: 100)
    #expect(playback.time == playback.duration)
    playback.togglePlayback()
    playback.setWindowVisible(false)
    #expect(!playback.isPlaying)
    playback.setWindowVisible(true)
    #expect(playback.isPlaying)
    playback.stop()
    #expect(!playback.isPlaying && playback.duration == 0)
    #expect(playback.player.items().isEmpty)
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
    #expect(!playback.wantsPlayback)
    playback.stepFrame(-1)
    #expect(abs(playback.time - 0.3) < 0.001)
  }

  private func makeVideo(at url: URL) async throws {
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
    for index in 0 ..< 10 {
      while !input.isReadyForMoreMediaData {
        try await Task.sleep(for: .milliseconds(1))
      }
      #expect(adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(index), timescale: 10)))
    }
    writer.endSession(atSourceTime: CMTime(value: 1, timescale: 1))
    input.markAsFinished()
    await writer.finishWriting()
    #expect(writer.status == .completed)
  }
}
