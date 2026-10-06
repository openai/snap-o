import AVFoundation
import Dependencies
import Foundation
import Testing

struct CaptureReviewPlaybackTests {
  @Test(arguments: [(0.0, "00:00"), (61.9, "01:01"), (3661.0, "1:01:01"), (Double.nan, "00:00")])
  @MainActor
  func formatsTimestamp(input: (Double, String)) {
    #expect(CaptureReviewPlayback.timestamp(input.0) == input.1)
  }

  @Test
  @MainActor
  func hiddenPaneStaysPausedWhenTheWindowBecomesVisible() async {
    let driver = PlaybackSpy()
    await withDependencies {
      $0.videoFiles.inspect = { _ in VideoFileInfo(duration: 3, size: CGSize(width: 64, height: 32)) }
    } operation: {
      let playback = CaptureReviewPlayback(driver: driver)
      await playback.load(URL(filePath: "/unused.mp4"))
      playback.setWindowVisible(true)
      #expect(driver.rate == 1)
      playback.setPaneVisible(false)
      playback.setWindowVisible(true)
      #expect(driver.rate == nil)
      #expect(playback.wantsPlayback)
      playback.setPaneVisible(true)
      #expect(driver.rate == 1)
      playback.stop()
      #expect(driver.rate == nil)
    }
  }

  @Test
  @MainActor
  func trimmingPassesBoundsAndRestoresPlayback() async {
    let driver = PlaybackSpy()
    await withDependencies {
      $0.videoFiles.inspect = { _ in VideoFileInfo(duration: 3, size: CGSize(width: 64, height: 32), frameRate: 30) }
    } operation: {
      let playback = CaptureReviewPlayback(driver: driver)
      await playback.load(URL(filePath: "/unused.mp4"))
      playback.setWindowVisible(true)
      playback.setSpeed(2)
      playback.seek(to: 0.5)
      playback.beginTrimming()
      #expect(driver.trimming && driver.rate == nil)
      playback.setTrimStart(1)
      playback.setTrimEnd(2)
      playback.togglePlayback()
      #expect(driver.rate == 1 && driver.end == 2)
      playback.cancelTrimming()
      #expect(!driver.trimming && driver.rate == 2)
      #expect(driver.position == 0.5)
      playback.beginTrimming()
      playback.setTrimStart(1)
      playback.setTrimEnd(2)
      #expect(playback.confirmTrim() == CaptureTrimRange(start: 1, end: 2))
      #expect(driver.range == CaptureTrimRange(start: 1, end: 2))
      #expect(driver.rate == nil)
      playback.stop()
    }
  }

  @Test
  func playbackControlsStayWithinPane() {
    for size in [CGSize(width: 260, height: 500), CGSize(width: 400, height: 800), CGSize(width: 800, height: 400)] {
      for ratio: CGFloat in [0.5, 1, 2] {
        let video = CaptureReviewLayout.mediaFrame(in: size, aspectRatio: ratio, showsPlayback: true)
        let controls = CaptureReviewLayout.playbackFrame(in: size)
        #expect(controls.maxY <= size.height)
        #expect(video.maxY + CaptureReviewLayout.playbackSpacing <= controls.minY + 0.0001)
        #expect(controls.minX >= CaptureReviewLayout.edgeSpacing)
        #expect(controls.maxX <= size.width - CaptureReviewLayout.edgeSpacing)
      }
    }
  }

  @Test
  func rapidScrubbingSettlesOnExactFinalPosition() throws {
    var seeks = CaptureSeekQueue()
    seeks.enqueue(time: 0.1, tolerance: 1.0 / 15)
    let firstRequest = seeks.next()
    let first = try #require(firstRequest)
    for time in [0.2, 0.7, 0.9] {
      seeks.enqueue(time: time, tolerance: 1.0 / 15)
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

@MainActor
private final class PlaybackSpy: CapturePlaybackDriver {
  var player: AVQueuePlayer? {
    nil
  }

  var rate: Float?
  var end: Double?
  var position = 0.0
  var range = CaptureTrimRange(start: 0, end: 0)
  var trimming = false
  func load(_ url: URL, onTime: @escaping @MainActor (Double) -> Void) {}
  func configure(range: CaptureTrimRange, isTrimming: Bool, onEnd: @escaping @MainActor () -> Void) {
    self.range = range
    trimming = isTrimming
  }

  func setPlayback(rate: Float?, end: Double?) {
    self.rate = rate
    self.end = end
  }

  func seek(_ request: CaptureSeekQueue.Request, completion: @escaping @MainActor () -> Void) {
    position = request.time
    completion()
  }

  func stop() {
    rate = nil
  }
}
