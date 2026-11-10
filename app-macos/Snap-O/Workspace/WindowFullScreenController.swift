import AppKit

@MainActor
final class WindowFullScreenController {
  enum Event {
    case willChange
    case didChange(windowIsVisible: Bool)
  }

  var onChange: (Event) -> Void = { _ in }
  private weak var window: NSWindow?
  private var isInFullScreen = false
  private var windowedFrame: NSRect?
  private var animationStartFrame: NSRect?
  private var awaitsVisibility = false
  private(set) var visibilityReport: Task<Void, Never>?

  var usesFullScreenFrame: Bool {
    // AppKit can resize before it adds or after it removes the fullScreen style mask.
    isInFullScreen || window?.styleMask.contains(.fullScreen) == true
  }

  func attach(to window: NSWindow) {
    visibilityReport?.cancel()
    visibilityReport = nil
    awaitsVisibility = false
    windowedFrame = nil
    animationStartFrame = nil
    self.window = window
    isInFullScreen = window.styleMask.contains(.fullScreen)
  }

  func willEnter() {
    windowedFrame = window?.frame
    isInFullScreen = true
    beginChange()
  }

  func didEnter() {
    isInFullScreen = true
    finishChange()
  }

  func willExit() {
    beginChange()
  }

  func didExit() {
    isInFullScreen = false
    windowedFrame = nil
    finishChange()
  }

  func failedToEnter(_ window: NSWindow) {
    cancelAnimation(in: window)
    didExit()
  }

  func failedToExit(_ window: NSWindow) {
    cancelAnimation(in: window)
    finishChange()
  }

  func animateEntry(_ window: NSWindow, on screen: NSScreen, duration: TimeInterval) {
    animationStartFrame = windowedFrame ?? window.frame
    window.animateWorkspaceFrame(to: screen.frame, duration: duration)
  }

  func windowsForExit(_ window: NSWindow) -> [NSWindow]? {
    guard let windowedFrame, window.screen?.frame.intersects(windowedFrame) == true else { return nil }
    return [window]
  }

  func animateExit(_ window: NSWindow, duration: TimeInterval) {
    guard let windowedFrame else { return }
    animationStartFrame = window.frame
    window.animateWorkspaceFrame(to: windowedFrame, duration: duration)
  }

  func reportVisibility() {
    guard awaitsVisibility, let window else { return }
    visibilityReport?.cancel()
    visibilityReport = Task { @MainActor [weak self, weak window] in
      guard !Task.isCancelled, let self, let window, self.window === window else { return }
      let visible = window.isVisibleForPlayback
      // The destination can become key before WindowServer uncovers it.
      if !visible, window.isKeyWindow, window.isVisible, !window.isMiniaturized { return }
      awaitsVisibility = false
      onChange(.didChange(windowIsVisible: visible))
    }
  }

  private func beginChange() {
    visibilityReport?.cancel()
    awaitsVisibility = false
    onChange(.willChange)
  }

  private func finishChange() {
    animationStartFrame = nil
    awaitsVisibility = true
    reportVisibility()
  }

  private func cancelAnimation(in window: NSWindow) {
    guard let animationStartFrame else { return }
    // Replacing the frame animation stops it from moving the window after rollback.
    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0
      window.animator().setFrame(animationStartFrame, display: true)
    }
  }
}
