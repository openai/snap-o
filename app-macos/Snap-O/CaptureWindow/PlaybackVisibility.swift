/// Preserves a user's pause choice when a recording is covered and uncovered.
struct PlaybackVisibility {
  var isViewVisible = false
  private(set) var isWindowVisible = false
  private var shouldResume = true

  var shouldPlay: Bool {
    isViewVisible && isWindowVisible && shouldResume
  }

  mutating func updateWindowVisibility(_ visible: Bool, wasPlaying: Bool) {
    guard visible != isWindowVisible else { return }
    if !visible { shouldResume = wasPlaying }
    isWindowVisible = visible
  }
}
