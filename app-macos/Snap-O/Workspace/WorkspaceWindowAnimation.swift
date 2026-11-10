import AppKit
import QuartzCore

extension NSWindow {
  func animateWorkspaceFrame(
    to frame: NSRect,
    duration: TimeInterval = 0.24,
    completion: @escaping @MainActor () -> Void = {}
  ) {
    guard duration > 0, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
      setFrame(frame, display: true, animate: false)
      completion()
      return
    }

    NSAnimationContext.runAnimationGroup { context in
      context.duration = duration
      context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
      animator().setFrame(frame, display: true)
    } completionHandler: {
      Task { @MainActor in completion() }
    }
  }
}
