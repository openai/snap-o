import AppKit
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

  @Test
  func confirmedTrimCanBeReopenedExpandedAndCancelled() {
    var session = CaptureTrimSession(duration: 3, frameRate: 10)
    session.begin(time: 0, playing: true)
    session.setStart(1.1)
    session.setEnd(1.7)
    let trimmed = session.confirm()
    #expect(trimmed == CaptureTrimRange(start: 1.1, end: 1.7))
    #expect(session.range == trimmed)

    session.begin(time: 1.1, playing: false)
    #expect(session.selection == trimmed)
    session.setStart(0)
    session.setEnd(3)
    session.cancel()
    #expect(session.range == trimmed)

    session.begin(time: 1.1, playing: false)
    session.setStart(0)
    session.setEnd(3)
    let expanded = session.confirm()
    #expect(expanded == nil)
    #expect(session.range == CaptureTrimRange(start: 0, end: 3))
  }

  @Test(arguments: [24.0, 30, 60, 29.97])
  func trimBoundsSnapToFramesAndKeepAtLeastOneFrame(rate: Double) {
    var session = CaptureTrimSession(duration: 3, frameRate: rate)
    session.begin(time: 0, playing: true)
    session.setStart(10.3 / rate)
    #expect(abs(session.selection.start - 10 / rate) < 0.000001)
    session.setEnd(20.7 / rate)
    #expect(abs(session.selection.end - 21 / rate) < 0.000001)
    session.setStart(100)
    #expect(abs(session.selection.duration - 1 / rate) < 0.000001)
    session.setEnd(-100)
    #expect(abs(session.selection.duration - 1 / rate) < 0.000001)
    session.setStart(-100)
    session.setEnd(100)
    #expect(session.selection == CaptureTrimRange(start: 0, end: 3))
    session.setStart(.infinity)
    session.setEnd(.nan)
    #expect(session.selection == CaptureTrimRange(start: 0, end: 3))
  }

  @Test(arguments: [false, true])
  func cancelPreservesSavedTrimAndReturnsOriginalPlayback(playing: Bool) throws {
    let saved = CaptureTrimRange(start: 0.5, end: 2.5)
    var session = CaptureTrimSession(duration: 3, frameRate: 10, trim: saved)
    session.begin(time: 1.2, playing: playing)
    session.setStart(1.5)
    // Entering trim again must not overwrite the original playback position.
    let beganAgain = session.begin(time: 2, playing: !playing)
    #expect(!beganAgain)
    let cancelled = session.cancel()
    let original = try #require(cancelled)
    #expect(session.range == saved)
    #expect(original.time == 1.2 && original.playing == playing)
    #expect(!session.isEditing)
  }
}
