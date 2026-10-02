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
  func scrubbingPreservesPauseChoice() async {
    let driver = TestCapturePlaybackDriver()
    let playback = CaptureReviewPlayback(driver: driver)
    await playback.load(TestCapturePlaybackDriver.url)
    driver.completeAllSeeks()
    playback.togglePlayback()
    playback.setScrubbing(true)
    playback.setScrubbing(false)
    #expect(!playback.wantsPlayback)
  }

  @Test @MainActor
  func visibilityChangesPreservePauseChoice() async {
    let driver = TestCapturePlaybackDriver()
    let playback = CaptureReviewPlayback(driver: driver)
    await playback.load(TestCapturePlaybackDriver.url)
    driver.completeAllSeeks()
    playback.togglePlayback()
    playback.setWindowVisible(false)
    playback.setWindowVisible(true)
    #expect(!playback.wantsPlayback)
  }

  @Test @MainActor
  func scrubbingPreservesPlaybackSpeed() async {
    let driver = TestCapturePlaybackDriver()
    let playback = CaptureReviewPlayback(driver: driver)
    await playback.load(TestCapturePlaybackDriver.url)
    driver.completeAllSeeks()
    playback.setSpeed(0.5)
    playback.setScrubbing(true)
    playback.setScrubbing(false)
    #expect(playback.speed == 0.5)
  }

  @Test @MainActor
  func scrubCoalescesSeeksAndResumesOnlyAfterExactCompletion() async {
    let driver = TestCapturePlaybackDriver()
    let playback = CaptureReviewPlayback(driver: driver)
    await playback.load(TestCapturePlaybackDriver.url)
    playback.setWindowVisible(true)
    playback.setSpeed(0.5)
    #expect(driver.rate == 0)
    driver.completeAllSeeks()
    #expect(driver.rate == 0.5)

    playback.setScrubbing(true)
    playback.seek(to: 0.2)
    let count = driver.requests.count
    for position in [0.4, 1.0, 2.2] {
      playback.seek(to: position)
    }
    driver.onTime?(0.7)
    #expect(playback.time == 2.2)
    #expect(driver.rate == 0)
    #expect(driver.requests.count == count)
    #expect(driver.requests.last?.tolerance == 1.0 / 15)

    playback.setScrubbing(false)
    driver.completeNextSeek()
    #expect(driver.requests.count == count + 1)
    #expect(driver.requests.last?.time == 2.2)
    #expect(driver.requests.last?.tolerance == 0)
    #expect(driver.rate == 0)
    driver.onTime?(0.8)
    #expect(playback.time == 2.2)
    driver.completeNextSeek()
    #expect(driver.rate == 0.5)
    driver.onTime?(2.3)
    #expect(playback.time == 2.3)
    driver.onTime?(.nan)
    #expect(playback.time == 2.3)
    driver.onTime?(10)
    #expect(playback.time == 3)
    driver.onTime?(-1)
    #expect(playback.time == 0)
  }

  @Test @MainActor
  func replacementAndStopIgnoreOldPlayerCallbacks() async {
    let driver = TestCapturePlaybackDriver()
    let playback = CaptureReviewPlayback(driver: driver)
    await playback.load(TestCapturePlaybackDriver.url)
    let oldTime = driver.onTime
    playback.setWindowVisible(true)
    await playback.load(TestCapturePlaybackDriver.url, trim: CaptureTrimRange(start: 1, end: 2))
    oldTime?(2.8)
    #expect(playback.time == 1)
    driver.completeNextSeek()
    #expect(driver.rate == 0)
    driver.completeNextSeek()
    #expect(driver.rate == 1)
    let currentTime = driver.onTime
    playback.seek(to: 1.5)
    playback.stop()
    currentTime?(2)
    driver.completeAllSeeks()
    #expect(playback.time == 0 && playback.duration == 0)
    #expect(!playback.isPlaying && !playback.canTrim)
    #expect(driver.rate == 0)
  }

  @Test @MainActor
  func visibilityAndFrameSteppingControlThePlayer() async {
    let driver = TestCapturePlaybackDriver()
    let playback = CaptureReviewPlayback(driver: driver)
    await playback.load(TestCapturePlaybackDriver.url)
    driver.completeAllSeeks()
    #expect(driver.rate == 0)
    playback.setWindowVisible(true)
    #expect(driver.rate == 1)
    playback.setWindowVisible(false)
    #expect(driver.rate == 0 && playback.wantsPlayback)
    playback.setWindowVisible(true)
    playback.stepFrame(1)
    #expect(abs(playback.time - 0.1) < 0.000001)
    #expect(!playback.wantsPlayback && driver.rate == 0)
    driver.completeAllSeeks()
    #expect(driver.rate == 0)
    playback.seek(to: .infinity)
    #expect(abs(playback.time - 0.1) < 0.000001)
    playback.stepFrame(-1)
    #expect(playback.time == 0)
  }

  @Test(arguments: [Double.nan, 0, 0.5, 29.97, 60]) @MainActor
  func metadataControlsFrameRate(rate: Double) async {
    let driver = TestCapturePlaybackDriver()
    driver.metadata = CapturePlaybackMetadata(duration: 3, frameRate: rate)
    let playback = CaptureReviewPlayback(driver: driver)
    await playback.load(TestCapturePlaybackDriver.url, trim: CaptureTrimRange(start: 2, end: 1))
    #expect(playback.frameRate == (rate.isFinite && rate >= 1 ? rate : 30))
    #expect(playback.playbackRange == CaptureTrimRange(start: 0, end: 3))
  }

  @Test(arguments: [0.0, -1, Double.nan, Double.infinity]) @MainActor
  func invalidDurationDoesNotActivatePlayback(duration: Double) async {
    let driver = TestCapturePlaybackDriver()
    driver.metadata = CapturePlaybackMetadata(duration: duration, frameRate: 30)
    let playback = CaptureReviewPlayback(driver: driver)
    await playback.load(TestCapturePlaybackDriver.url)
    #expect(playback.errorMessage != nil)
    #expect(!playback.canTrim && !playback.isPlaying)
    #expect(driver.requests.isEmpty)
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
