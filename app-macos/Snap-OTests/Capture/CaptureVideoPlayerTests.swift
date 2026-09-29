import AppKit
@testable import Snap_O
import Testing

@Suite("Capture video keyboard focus", .serialized)
@MainActor
struct CaptureVideoPlayerTests {
  @Test
  func customPlaybackKeysRespectModifiers() throws {
    let player = CaptureVideoPlayer.PlayerView()
    var steps: [Int] = []
    var toggles = 0
    player.stepFrame = { steps.append($0) }
    player.togglePlayback = { toggles += 1 }
    func event(_ code: UInt16, modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
      try #require(NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
        windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
        isARepeat: false, keyCode: code
      ))
    }
    #expect(player.acceptsFirstResponder)
    #expect(try player.handlePlaybackKey(event(123)))
    #expect(try player.handlePlaybackKey(event(124)))
    #expect(try player.handlePlaybackKey(event(49)))
    #expect(try !player.handlePlaybackKey(event(123, modifiers: .command)))
    #expect(steps == [-1, 1])
    #expect(toggles == 1)
  }

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
