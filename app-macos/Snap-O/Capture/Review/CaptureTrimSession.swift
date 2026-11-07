import Foundation

/// Keeps a draft trim separate from the saved range until it is confirmed.
struct CaptureTrimSession {
  let duration: Double
  let frameRate: Double
  private(set) var selection = CaptureTrimRange(start: 0, end: 0)
  private var saved: CaptureTrimRange?
  private var originalPlayback: (time: Double, playing: Bool)?

  init(duration: Double = 0, frameRate: Double = 30, trim: CaptureTrimRange? = nil) {
    self.duration = duration
    self.frameRate = frameRate
    saved = trim?.isValid(for: duration) == true ? trim : nil
  }

  var isEditing: Bool {
    originalPlayback != nil
  }

  var range: CaptureTrimRange {
    isEditing ? selection : saved ?? CaptureTrimRange(start: 0, end: duration)
  }

  @discardableResult
  mutating func begin(time: Double, playing: Bool) -> Bool {
    guard !isEditing, duration > 1 / frameRate else { return false }
    selection = range
    originalPlayback = (time, playing)
    return true
  }

  @discardableResult
  mutating func cancel() -> (time: Double, playing: Bool)? {
    let playback = originalPlayback
    originalPlayback = nil
    return playback
  }

  mutating func confirm() -> CaptureTrimRange? {
    guard isEditing else { return saved }
    saved = selection == CaptureTrimRange(start: 0, end: duration) ? nil : selection
    originalPlayback = nil
    return saved
  }

  mutating func setStart(_ seconds: Double) {
    guard isEditing, seconds.isFinite else { return }
    let start = min(max(0, snapped(seconds)), max(0, selection.end - 1 / frameRate))
    selection = CaptureTrimRange(start: start, end: selection.end)
  }

  mutating func setEnd(_ seconds: Double) {
    guard isEditing, seconds.isFinite else { return }
    let end = max(min(duration, snapped(seconds)), selection.start + 1 / frameRate)
    selection = CaptureTrimRange(start: selection.start, end: min(duration, end))
  }

  private func snapped(_ seconds: Double) -> Double {
    (seconds * frameRate).rounded() / frameRate
  }
}
