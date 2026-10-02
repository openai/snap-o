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
        let controls = CaptureReviewLayout.playbackFrame(in: size)
        #expect(abs(controls.maxY - (size.height - CaptureReviewLayout.edgeSpacing)) < 0.0001)
        #expect(video.maxY + CaptureReviewLayout.playbackSpacing <= controls.minY + 0.0001)
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

  @Test
  func rapidScrubbingSettlesOnExactFinalPosition() throws {
    var seeks = CaptureSeekQueue()
    seeks.enqueue(time: 0.1, tolerance: 1.0 / 15)
    let firstRequest = seeks.next()
    let first = try #require(firstRequest)
    for index in 0 ..< 200 {
      seeks.enqueue(time: Double(index % 9) / 10, tolerance: 1.0 / 15)
      let concurrent = seeks.next()
      #expect(concurrent == nil)
    }
    seeks.enqueue(time: 0.4, tolerance: 0)
    let finishedFirst = seeks.complete(first)
    #expect(finishedFirst)
    let finalRequest = seeks.next()
    let final = try #require(finalRequest)
    #expect(final.time == 0.4 && final.tolerance == 0)
    #expect(seeks.isSeeking)
    let finishedFinal = seeks.complete(final)
    #expect(finishedFinal)
    let next = seeks.next()
    #expect(next == nil && !seeks.isSeeking)
  }

  @Test
  func staleCompletionCannotFinishANewSeek() throws {
    var seeks = CaptureSeekQueue()
    seeks.enqueue(time: 0.1, tolerance: 0)
    let oldRequest = seeks.next()
    let old = try #require(oldRequest)
    seeks = CaptureSeekQueue()
    seeks.enqueue(time: 0.7, tolerance: 0)
    let currentRequest = seeks.next()
    let current = try #require(currentRequest)
    let finishedOld = seeks.complete(old)
    #expect(!finishedOld)
    #expect(seeks.isSeeking)
    let finishedCurrent = seeks.complete(current)
    #expect(finishedCurrent)
  }
}
