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

  @Test @MainActor
  func scrubbingPreservesPauseChoice() {
    let recorder = CapturePlaybackOutput()
    let playback = CaptureReviewPlayback(duration: 3, frameRate: 10, output: recorder.output)
    recorder.completeAllSeeks()
    playback.togglePlayback()
    playback.setScrubbing(true)
    playback.setScrubbing(false)
    #expect(!playback.wantsPlayback)
  }

  @Test @MainActor
  func visibilityChangesPreservePauseChoice() {
    let recorder = CapturePlaybackOutput()
    let playback = CaptureReviewPlayback(duration: 3, frameRate: 10, output: recorder.output)
    recorder.completeAllSeeks()
    playback.togglePlayback()
    playback.setWindowVisible(false)
    playback.setWindowVisible(true)
    #expect(!playback.wantsPlayback)
  }

  @Test @MainActor
  func scrubbingPreservesPlaybackSpeed() {
    let recorder = CapturePlaybackOutput()
    let playback = CaptureReviewPlayback(duration: 3, frameRate: 10, output: recorder.output)
    recorder.completeAllSeeks()
    playback.setSpeed(0.5)
    playback.setScrubbing(true)
    playback.setScrubbing(false)
    #expect(playback.speed == 0.5)
  }

  @Test @MainActor
  func scrubCoalescesSeeksAndResumesOnlyAfterExactCompletion() {
    let recorder = CapturePlaybackOutput()
    let playback = CaptureReviewPlayback(duration: 3, frameRate: 10, output: recorder.output)
    playback.setWindowVisible(true)
    playback.setSpeed(0.5)
    #expect(recorder.rate == 0)
    recorder.completeAllSeeks()
    #expect(recorder.rate == 0.5)

    playback.setScrubbing(true)
    playback.seek(to: 0.2)
    let count = recorder.requests.count
    for position in [0.4, 1.0, 2.2] {
      playback.seek(to: position)
    }
    playback.didUpdateTime(0.7)
    #expect(playback.time == 2.2)
    #expect(recorder.rate == 0)
    #expect(recorder.requests.count == count)
    #expect(recorder.requests.last?.tolerance == 1.0 / 15)

    playback.setScrubbing(false)
    recorder.completeNextSeek()
    #expect(recorder.requests.count == count + 1)
    #expect(recorder.requests.last?.time == 2.2)
    #expect(recorder.requests.last?.tolerance == 0)
    #expect(recorder.rate == 0)
    playback.didUpdateTime(0.8)
    #expect(playback.time == 2.2)
    recorder.completeNextSeek()
    #expect(recorder.rate == 0.5)
    playback.didUpdateTime(2.3)
    #expect(playback.time == 2.3)
    playback.didUpdateTime(.nan)
    #expect(playback.time == 2.3)
    playback.didUpdateTime(10)
    #expect(playback.time == 3)
    playback.didUpdateTime(-1)
    #expect(playback.time == 0)
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
