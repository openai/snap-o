@testable import Snap_O
import Testing

struct PlaybackVisibilityTests {
  @Test
  func requiresBothViewAndWindowVisibility() {
    var visibility = PlaybackVisibility()
    #expect(!visibility.shouldPlay)
    visibility.isViewVisible = true
    #expect(!visibility.shouldPlay)
    visibility.updateWindowVisibility(true, wasPlaying: false)
    #expect(visibility.shouldPlay)
    visibility.isViewVisible = false
    #expect(!visibility.shouldPlay)
  }

  @Test(arguments: [false, true])
  func uncoverPreservesPlaybackChoice(wasPlaying: Bool) {
    var visibility = PlaybackVisibility()
    visibility.isViewVisible = true
    visibility.updateWindowVisibility(true, wasPlaying: false)
    visibility.updateWindowVisibility(false, wasPlaying: wasPlaying)
    #expect(!visibility.shouldPlay)
    // Repeated hidden notifications must not replace the remembered choice.
    visibility.updateWindowVisibility(false, wasPlaying: false)
    visibility.updateWindowVisibility(true, wasPlaying: false)
    #expect(visibility.shouldPlay == wasPlaying)
  }
}
