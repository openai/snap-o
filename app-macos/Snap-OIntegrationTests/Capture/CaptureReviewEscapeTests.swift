import AppKit
@testable import Snap_O
import SwiftUI
import Testing

@Suite(.serialized)
@MainActor
struct CaptureReviewEscapeTests {
  @Test
  func eachNewReviewReceivesEscape() async throws {
    let window = makeWindow()
    defer { close(window) }
    let exits = TestValue<[Int]>([])

    for reviewID in 1 ... 3 {
      // Removing the old hierarchy models leaving review, then opening another capture.
      window.contentView = NSView()
      let previousResponder = window.focusedResponder.value
      window.contentView = NSHostingView(rootView:
        Color.clear.captureReviewKeyboard { exits.value.append(reviewID) }
      )
      window.contentView?.layoutSubtreeIfNeeded()
      try await waitForState {
        window.focusedResponder.value is CaptureReviewFocus.FocusView
          && window.focusedResponder.value !== previousResponder
      }
      try sendEscape(to: window)
      try await waitForState { exits.value.count >= reviewID }
      #expect(exits.value == Array(1 ... reviewID))
    }
  }

  @Test
  func nativeVideoFocusStillRoutesEscapeToReview() async throws {
    let window = makeWindow()
    defer { close(window) }
    let exits = TestValue(0)
    window.contentView = NSHostingView(rootView:
      CaptureVideoPlayer(player: nil).captureReviewKeyboard { exits.value += 1 }
    )
    window.contentView?.layoutSubtreeIfNeeded()
    try await waitForState { window.focusedResponder.value is CaptureReviewFocus.FocusView }
    let player = try #require(videoPlayer(in: window.contentView))
    defer { player.stopMonitoring() }
    player.focusPlayer()
    let responder = try #require(window.firstResponder as? NSView)
    try #require(responder === player || responder.isDescendant(of: player))

    try sendEscape(to: window)

    try await waitForState { exits.value > 0 }
    #expect(exits.value == 1)
  }

  private func makeWindow() -> FocusWindow {
    FocusWindow(
      contentRect: CGRect(x: 0, y: 0, width: 160, height: 120),
      styleMask: [.titled], backing: .buffered, defer: false
    )
  }

  private func close(_ window: NSWindow) {
    window.orderOut(nil)
    window.contentView = nil
  }

  private func sendEscape(to window: NSWindow) throws {
    let event = try #require(NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
      windowNumber: window.windowNumber, context: nil, characters: "\u{1B}",
      charactersIgnoringModifiers: "\u{1B}", isARepeat: false, keyCode: 53
    ))
    window.sendEvent(event)
  }

  private func videoPlayer(in view: NSView?) -> CaptureVideoPlayer.PlayerView? {
    if let player = view as? CaptureVideoPlayer.PlayerView { return player }
    for child in view?.subviews ?? [] {
      if let player = videoPlayer(in: child) { return player }
    }
    return nil
  }
}

@MainActor
private final class FocusWindow: NSWindow {
  let focusedResponder = TestValue<NSResponder?>(nil)

  override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
    let accepted = super.makeFirstResponder(responder)
    if accepted { focusedResponder.value = firstResponder }
    return accepted
  }
}
