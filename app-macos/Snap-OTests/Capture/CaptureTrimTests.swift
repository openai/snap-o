import AppKit
@testable import Snap_O
import Testing

struct CaptureTrimTests {
  @Test(arguments: [24.0, 30, 60, 29.97])
  func timecodesRoundTripFrameBoundaries(frameRate: Double) throws {
    let timecode = CaptureTrimTimecode(frameRate: frameRate)
    for frame in [0, 1, 29, 30, 1799, 1800, 108_123] {
      let seconds = Double(frame) / frameRate
      let decoded = try #require(timecode.seconds(from: timecode.string(for: seconds)))
      #expect(abs(decoded - seconds) < 0.000001)
    }
  }

  @Test(arguments: ["", "12", "00:00", "-1:00:00", "00:60:00", "00:00:30", "00:01:02:03", "00:NaN:00", "999999999999999999999:00:00"])
  func rejectsInvalidTimecodes(text: String) {
    #expect(CaptureTrimTimecode(frameRate: 30).seconds(from: text) == nil)
  }

  @Test
  func trimControlsStayWithinNarrowAndWidePanes() {
    for width: CGFloat in [260, 360, 380, 400, 800] {
      let size = CGSize(width: width, height: 500)
      let video = CaptureReviewLayout.mediaFrame(in: size, aspectRatio: 0.5, showsPlayback: true, isTrimming: true)
      let controls = CaptureReviewLayout.playbackFrame(in: size, isTrimming: true)
      #expect(abs(controls.maxY - (size.height - CaptureReviewLayout.edgeSpacing)) < 0.0001)
      #expect(video.maxY + CaptureReviewLayout.playbackSpacing <= controls.minY + 0.0001)
      #expect(controls.minX >= CaptureReviewLayout.edgeSpacing)
      #expect(controls.maxX <= size.width - CaptureReviewLayout.edgeSpacing)
    }
  }

  @Test @MainActor
  func trimmingClampsToOneFrameAndCancelRestoresPlayback() async {
    let driver = TestCapturePlaybackDriver()
    let playback = CaptureReviewPlayback(driver: driver)
    await playback.load(TestCapturePlaybackDriver.url)
    defer { playback.stop() }
    #expect(playback.canTrim)
    playback.setSpeed(0.5)
    playback.seek(to: 1.2)
    playback.beginTrimming()
    #expect(!playback.wantsPlayback)
    playback.setTrimStart(1.14)
    #expect(abs(playback.trimSelection.start - 1.1) < 0.0001)
    playback.setTrimEnd(0)
    #expect(abs(playback.trimSelection.duration - 0.1) < 0.0001)
    playback.setTrimStart(100)
    #expect(playback.trimSelection.isValid(for: playback.duration))
    #expect(abs(playback.trimSelection.duration - 0.1) < 0.0001)
    playback.setTrimEnd(.nan)
    #expect(playback.trimSelection.isValid(for: playback.duration))
    playback.cancelTrimming()
    #expect(!playback.isTrimming)
    #expect(playback.playbackRange == CaptureTrimRange(start: 0, end: 3))
    #expect(playback.wantsPlayback && playback.speed == 0.5)
    #expect(abs(playback.time - 1.2) < 0.0001)
  }

  @Test @MainActor
  func confirmedTrimCanBeReopenedExpandedAndCancelled() async {
    let driver = TestCapturePlaybackDriver()
    let playback = CaptureReviewPlayback(driver: driver)
    await playback.load(TestCapturePlaybackDriver.url)
    defer { playback.stop() }
    playback.beginTrimming()
    playback.setTrimStart(1.1)
    playback.setTrimEnd(1.7)
    let trimmed = playback.confirmTrim()
    #expect(driver.loops && driver.range == trimmed)
    driver.completeAllSeeks()
    #expect(driver.rate == 0 && !playback.wantsPlayback)
    #expect(trimmed == CaptureTrimRange(start: 1.1, end: 1.7))
    #expect(abs(playback.playbackRange.duration - 0.6) < 0.0001)
    #expect(playback.elapsedTime == 0)
    playback.seek(to: 0)
    #expect(playback.time == 1.1)
    playback.beginTrimming()
    playback.setTrimStart(0)
    playback.setTrimEnd(3)
    playback.cancelTrimming()
    #expect(playback.playbackRange == trimmed)
    #expect(!playback.wantsPlayback)
    playback.beginTrimming()
    playback.setTrimStart(0)
    playback.setTrimEnd(3)
    #expect(playback.confirmTrim() == nil)
  }

  @Test @MainActor
  func draggingTrimEndDoesNotChangeThePlayerStopTime() async {
    let driver = TestCapturePlaybackDriver()
    let playback = CaptureReviewPlayback(driver: driver)
    await playback.load(TestCapturePlaybackDriver.url)
    defer { playback.stop() }
    playback.beginTrimming()
    playback.setScrubbing(true)
    for end in [2.8, 2.1, 1.4, 0.5, 2.7] {
      playback.setTrimEnd(end)
      #expect(driver.playbackEnd == nil)
      #expect(abs(playback.time - (end - 1 / playback.frameRate)) < 0.0001)
    }
    playback.setScrubbing(false)
    #expect(driver.playbackEnd == nil)
    #expect(!playback.wantsPlayback)
  }

  @Test @MainActor
  func trimPreviewStopsAtItsEndAndRestartsAtItsStart() async {
    let driver = TestCapturePlaybackDriver()
    let playback = CaptureReviewPlayback(driver: driver)
    await playback.load(TestCapturePlaybackDriver.url)
    defer { playback.stop() }
    playback.setWindowVisible(true)
    playback.beginTrimming()
    playback.setTrimStart(1.1)
    playback.setScrubbing(true)
    playback.setTrimEnd(1.4)
    playback.setScrubbing(false)
    driver.completeAllSeeks()
    playback.togglePlayback()
    driver.completeAllSeeks()
    #expect(driver.playbackEnd == playback.trimSelection.end)
    #expect(driver.rate == 1)
    driver.onEnd?()
    #expect(!playback.wantsPlayback)
    #expect(driver.rate == 0)
    #expect(playback.time >= 1.1 && playback.time < 1.4)
    playback.togglePlayback()
    #expect(playback.wantsPlayback)
    #expect(abs(playback.time - 1.1) < 0.0001)
    playback.setScrubbing(true)
    playback.setTrimEnd(1.8)
    playback.setScrubbing(false)
    playback.togglePlayback()
    driver.completeAllSeeks()
    #expect(driver.playbackEnd == playback.trimSelection.end)
    #expect(driver.rate == 1)
    driver.onEnd?()
    #expect(!playback.wantsPlayback)
    #expect(driver.rate == 0)
    #expect(playback.time >= 1.7 && playback.time < 1.8)
  }

  @Test(arguments: [24.0, 30, 60, 29.97]) @MainActor
  func trimBoundsSnapToFramesAndKeepAtLeastOneFrame(rate: Double) async {
    let driver = TestCapturePlaybackDriver()
    driver.metadata = CapturePlaybackMetadata(duration: 3, frameRate: rate)
    let playback = CaptureReviewPlayback(driver: driver)
    await playback.load(TestCapturePlaybackDriver.url)
    playback.beginTrimming()
    playback.setTrimStart(10.3 / rate)
    #expect(abs(playback.trimSelection.start - 10 / rate) < 0.000001)
    playback.setTrimEnd(20.7 / rate)
    #expect(abs(playback.trimSelection.end - 21 / rate) < 0.000001)
    playback.setTrimStart(100)
    #expect(abs(playback.trimSelection.duration - 1 / rate) < 0.000001)
    playback.setTrimEnd(-100)
    #expect(abs(playback.trimSelection.duration - 1 / rate) < 0.000001)
    playback.setTrimStart(-100)
    playback.setTrimEnd(100)
    #expect(playback.trimSelection == CaptureTrimRange(start: 0, end: 3))
    playback.setTrimStart(.infinity)
    playback.setTrimEnd(.nan)
    #expect(playback.trimSelection == CaptureTrimRange(start: 0, end: 3))
  }

  @Test(arguments: [false, true]) @MainActor
  func cancelRestoresPositionSpeedAndPauseChoice(playing: Bool) async {
    let driver = TestCapturePlaybackDriver()
    let playback = CaptureReviewPlayback(driver: driver)
    let saved = CaptureTrimRange(start: 0.5, end: 2.5)
    await playback.load(TestCapturePlaybackDriver.url, trim: saved)
    playback.setWindowVisible(true)
    playback.setSpeed(0.5)
    if !playing { playback.togglePlayback() }
    playback.seek(to: 1.2)
    driver.completeAllSeeks()
    playback.beginTrimming()
    #expect(!driver.loops)
    playback.setTrimStart(1.5)
    playback.cancelTrimming()
    #expect(playback.playbackRange == saved)
    #expect(playback.time == 1.2 && playback.speed == 0.5)
    #expect(playback.wantsPlayback == playing)
    #expect(driver.loops && driver.range == saved)
    #expect(driver.rate == 0)
    driver.completeAllSeeks()
    #expect(driver.rate == (playing ? 0.5 : 0))
  }

  @Test @MainActor
  func previewIgnoresEndEventsWhileSeekingScrubbingOrPaused() async {
    let driver = TestCapturePlaybackDriver()
    let playback = CaptureReviewPlayback(driver: driver)
    await playback.load(TestCapturePlaybackDriver.url)
    playback.setWindowVisible(true)
    playback.beginTrimming()
    playback.setTrimEnd(2)
    playback.togglePlayback()
    driver.onEnd?()
    #expect(playback.wantsPlayback)
    driver.completeAllSeeks()
    playback.setScrubbing(true)
    driver.onEnd?()
    #expect(playback.wantsPlayback)
    playback.setScrubbing(false)
    driver.completeAllSeeks()
    playback.togglePlayback()
    let position = playback.time
    driver.onEnd?()
    #expect(!playback.wantsPlayback && playback.time == position)
  }
}
