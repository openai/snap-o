import Foundation
@testable import Snap_O

@MainActor
final class TestCapturePlaybackDriver: CapturePlaybackDriver {
  static let url = URL(fileURLWithPath: "/synthetic.mp4")
  var metadata = CapturePlaybackMetadata(duration: 3, frameRate: 10)
  var range: CaptureTrimRange?
  var loops = false
  var playbackEnd: Double?
  var rate: Float = 0
  var onEnd: (@MainActor () -> Void)?
  var onTime: (@MainActor (Double) -> Void)?
  var requests: [(time: Double, tolerance: Double)] = []
  var completions: [@MainActor () -> Void] = []

  func load(_: URL) async throws -> CapturePlaybackMetadata {
    metadata
  }

  func configure(range: CaptureTrimRange, loops: Bool, onEnd: @escaping @MainActor () -> Void) {
    self.range = range
    self.loops = loops
    self.onEnd = onEnd
    playbackEnd = nil
  }

  func observeTime(_ onTime: @escaping @MainActor (Double) -> Void) {
    self.onTime = onTime
  }

  func seek(to seconds: Double, tolerance: Double, completion: @escaping @MainActor () -> Void) {
    requests.append((seconds, tolerance))
    completions.append(completion)
  }

  func completeNextSeek() {
    completions.removeFirst()()
  }

  func completeAllSeeks() {
    while !completions.isEmpty {
      completeNextSeek()
    }
  }

  func setPlaybackEnd(_ seconds: Double?) {
    playbackEnd = seconds
  }

  func play(atRate rate: Float) {
    self.rate = rate
  }

  func pause() {
    rate = 0
  }

  func stop() {
    rate = 0
    range = nil
    onEnd = nil
    onTime = nil
    playbackEnd = nil
    // Retain callbacks so tests can deliver completions from a replaced item.
  }
}
