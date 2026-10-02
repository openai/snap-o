import Foundation
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
        let controls = CaptureReviewLayout.playbackFrame(in: size)
        #expect(abs(controls.maxY - (size.height - CaptureReviewLayout.edgeSpacing)) < 0.0001)
        #expect(video.maxY + CaptureReviewLayout.playbackSpacing <= controls.minY + 0.0001)
        #expect(controls.minX >= CaptureReviewLayout.edgeSpacing)
        #expect(controls.maxX <= size.width - CaptureReviewLayout.edgeSpacing)
      }
    }
  }

  @Test(arguments: [false, true]) @MainActor
  func scrubKeepsLatestPositionAndRestoresPlaybackChoice(playing: Bool) throws {
    var playback = CapturePlaybackState(duration: 3, frameRate: 10)
    playback.setWindowVisible(true)
    playback.setSpeed(0.5)
    if !playing { playback.togglePlayback() }
    #expect(playback.playbackRate == 0)
    finishSeeks(&playback)
    #expect(playback.playbackRate == (playing ? 0.5 : 0))

    playback.setScrubbing(true)
    playback.seek(to: 0.2)
    let firstRequest = playback.nextSeek()
    let first = try #require(firstRequest)
    for position in [0.4, 1.0, 2.2] {
      playback.seek(to: position)
    }
    playback.didUpdateTime(0.7)
    #expect(playback.time == 2.2)
    #expect(playback.playbackRate == 0)
    let concurrent = playback.nextSeek()
    #expect(concurrent == nil)
    #expect(first.tolerance == 1.0 / 15)

    playback.setScrubbing(false)
    let completedFirst = playback.completeSeek(first)
    #expect(completedFirst)
    let finalRequest = playback.nextSeek()
    let final = try #require(finalRequest)
    #expect(final.time == 2.2)
    #expect(final.tolerance == 0)
    #expect(playback.playbackRate == 0)
    playback.didUpdateTime(0.8)
    #expect(playback.time == 2.2)
    let completedFinal = playback.completeSeek(final)
    #expect(completedFinal)
    #expect(playback.playbackRate == (playing ? 0.5 : 0))
    playback.didUpdateTime(2.3)
    #expect(playback.time == 2.3)
  }

  @Test @MainActor
  func enteringTrimIgnoresPreviousSeekCompletion() throws {
    var playback = CapturePlaybackState(duration: 3, frameRate: 10)
    let previousRequest = playback.nextSeek()
    let previous = try #require(previousRequest)
    playback.beginTrimming()
    let trimRequest = playback.nextSeek()
    let trim = try #require(trimRequest)

    let completedPrevious = playback.completeSeek(previous)
    #expect(!completedPrevious)
    #expect(playback.isSeeking)
    let completedTrim = playback.completeSeek(trim)
    #expect(completedTrim)
    #expect(!playback.isSeeking)
  }
}

func finishSeeks(_ state: inout CapturePlaybackState) {
  while let request = state.nextSeek() {
    let completed = state.completeSeek(request)
    #expect(completed)
  }
}
