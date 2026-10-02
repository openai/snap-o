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
  func confirmedTrimCanBeReopenedExpandedAndCancelled() {
    var playback = CapturePlaybackState(duration: 3, frameRate: 10)
    playback.beginTrimming()
    playback.setTrimStart(1.1)
    playback.setTrimEnd(1.7)
    let trimmed = playback.confirmTrim()
    finishSeeks(&playback)
    #expect(playback.playbackRate == 0 && !playback.wantsPlayback)
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
    let expanded = playback.confirmTrim()
    #expect(expanded == nil)
  }

  @Test @MainActor
  func previewEndEventLeavesLastFrameAndPlayRestartsSelection() {
    var playback = CapturePlaybackState(duration: 3, frameRate: 10)
    playback.setWindowVisible(true)
    playback.beginTrimming()
    playback.setTrimStart(1.1)
    playback.setTrimEnd(1.4)
    playback.togglePlayback()
    finishSeeks(&playback)
    #expect(playback.playbackEnd == 1.4)

    playback.didReachEnd()
    finishSeeks(&playback)
    #expect(playback.playbackRate == 0)
    #expect(abs(playback.time - 1.3) < 0.000001)

    playback.togglePlayback()
    #expect(abs(playback.time - 1.1) < 0.000001)
    finishSeeks(&playback)
    #expect(playback.playbackRate == 1)
  }

  @Test(arguments: [24.0, 30, 60, 29.97]) @MainActor
  func trimBoundsSnapToFramesAndKeepAtLeastOneFrame(rate: Double) {
    var playback = CapturePlaybackState(duration: 3, frameRate: rate)
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
  func cancelRestoresPositionSpeedAndPauseChoice(playing: Bool) {
    let saved = CaptureTrimRange(start: 0.5, end: 2.5)
    var playback = CapturePlaybackState(duration: 3, frameRate: 10, trim: saved)
    playback.setWindowVisible(true)
    playback.setSpeed(0.5)
    if !playing { playback.togglePlayback() }
    playback.seek(to: 1.2)
    finishSeeks(&playback)
    playback.beginTrimming()
    playback.setTrimStart(1.5)
    playback.cancelTrimming()
    #expect(playback.playbackRange == saved)
    #expect(playback.time == 1.2 && playback.speed == 0.5)
    #expect(playback.wantsPlayback == playing)
    #expect(playback.playbackRate == 0)
    finishSeeks(&playback)
    #expect(playback.playbackRate == (playing ? 0.5 : 0))
  }
}
