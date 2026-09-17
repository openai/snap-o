import AppKit
@testable import Snap_O
import Testing

@Suite("Capture video keyboard focus", .serialized)
@MainActor
struct CaptureVideoPlayerTests {
  @Test
  func focusLeavesTheWholePlayer() throws {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
      styleMask: [.borderless], backing: .buffered, defer: false
    )
    let content = try #require(window.contentView)
    let player = CaptureVideoPlayer.PlayerView(frame: NSRect(x: 0, y: 0, width: 320, height: 240))
    let firstControl = FocusTarget()
    let secondControl = FocusTarget()
    let outside = FocusTarget()
    player.addSubview(firstControl)
    player.addSubview(secondControl)
    content.addSubview(player)
    content.addSubview(outside)
    window.contentView = content
    defer {
      player.stopMonitoring()
      window.contentView = nil
    }
    var changes: [Bool] = []
    player.onFocusChange = { changes.append($0) }

    player.focusPlayer()
    #expect(changes == [true])
    for control in [firstControl, secondControl] {
      #expect(window.makeFirstResponder(control))
      window.update()
      #expect(changes == [true], "Moving between player controls must preserve keyboard ownership")
    }
    #expect(window.makeFirstResponder(outside))
    window.update()
    #expect(changes == [true, false], "Moving outside the player must release keyboard ownership")
    window.update()
    #expect(changes == [true, false], "Report focus loss once")

    player.focusPlayer()
    #expect(changes == [true, false, true])
    player.stopMonitoring()
    #expect(window.makeFirstResponder(outside))
    window.update()
    #expect(changes == [true, false, true], "Detached players must stop reporting focus changes")
  }
}

@MainActor
private final class FocusTarget: NSView {
  override var acceptsFirstResponder: Bool {
    true
  }
}
