import Foundation

struct CaptureTrimRange: Equatable {
  let start: Double
  let end: Double

  var duration: Double {
    end - start
  }

  func isValid(for duration: Double) -> Bool {
    start.isFinite && end.isFinite && start >= 0 && end > start && end <= duration
  }
}

/// Non-drop-frame timecode uses the recording's nominal frame rate.
struct CaptureTrimTimecode {
  let frameRate: Double

  init(frameRate: Double) {
    self.frameRate = frameRate.isFinite && frameRate >= 1 ? frameRate : 30
  }

  private var framesPerSecond: Int {
    Int(frameRate.rounded())
  }

  func string(for seconds: Double) -> String {
    let frames = Int((max(0, seconds.isFinite ? seconds : 0) * frameRate).rounded())
    let totalSeconds = frames / framesPerSecond
    return String(format: "%02d:%02d:%02d", totalSeconds / 60, totalSeconds % 60, frames % framesPerSecond)
  }

  func seconds(from text: String) -> Double? {
    let parts = text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ":", omittingEmptySubsequences: false)
    guard parts.count == 3,
          parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }),
          let minutes = Int(parts[0]), let seconds = Int(parts[1]), let frames = Int(parts[2]),
          minutes <= 99999, seconds < 60, frames < framesPerSecond else { return nil }
    return Double((minutes * 60 + seconds) * framesPerSecond + frames) / frameRate
  }
}
