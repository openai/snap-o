@testable import Snap_O

@MainActor
final class CapturePlaybackOutput {
  var rate: Float = 0
  var playbackEnd: Double?
  var requests: [(time: Double, tolerance: Double)] = []
  var completions: [@MainActor () -> Void] = []

  var output: CaptureReviewPlayback.Output {
    .init(
      seek: { [self] time, tolerance, completion in
        requests.append((time, tolerance))
        completions.append(completion)
      },
      update: { [self] rate, end in
        self.rate = rate
        playbackEnd = end
      }
    )
  }

  func completeNextSeek() {
    completions.removeFirst()()
  }

  func completeAllSeeks() {
    while !completions.isEmpty {
      completeNextSeek()
    }
  }
}
