import AppKit
import SwiftUI

/// Bridges SwiftUI and AppKit to keep a window sized to the current media
/// aspect ratio while enforcing a sensible minimum edge length. The first
/// window opens at 480×480 points; subsequent windows inherit the size of the
/// most recently active window. Only the focused window is marked restorable so
/// reopened sessions bring back that single window.
struct WindowSizingController: NSViewRepresentable {
  let displayInfo: DisplayInfo?

  private static let minimumEdge: CGFloat = 240

  func makeCoordinator() -> Coordinator {
    Coordinator(minimumEdge: Self.minimumEdge)
  }

  func makeNSView(context: Context) -> NSView {
    let view = NSView()
    DispatchQueue.main.async {
      guard let window = view.window else { return }
      context.coordinator.attach(to: window)
    }
    return view
  }

  func updateNSView(_ nsView: NSView, context: Context) {
    guard let displayInfo else { return }
    context.coordinator.sizeWindow(for: displayInfo)
  }

  // MARK: - Coordinator

  @MainActor
  final class Coordinator: NSObject, NSWindowDelegate {
    // MARK: Properties

    private weak var window: NSWindow?

    private let minimumEdge: CGFloat
    private var lastMediaStamp: Date?
    private var currentAspect: CGFloat = 1

    private weak static var restorableWindow: NSWindow?

    init(minimumEdge: CGFloat) {
      self.minimumEdge = minimumEdge
    }

    // MARK: Window Attachment

    /// Attach to a window once and configure delegate and restoration.
    func attach(to window: NSWindow) {
      guard self.window !== window else { return }
      self.window = window
      window.delegate = self
      window.setFrameAutosaveName("SnapOWindow")
      window.isRestorable = false
    }

    // MARK: Window Sizing

    /// Size the window to fit the given media while preserving aspect ratio
    /// and minimum content edge. Frame animations are dispatched on main to
    /// ensure proper AppKit animation.
    func sizeWindow(for displayInfo: DisplayInfo) {
      let targetContentSize = scaledContentSize(for: displayInfo)
      currentAspect = targetContentSize.width / max(targetContentSize.height, 1)

      guard let window else { return }
      let frame = frameFor(window: window, contentSize: targetContentSize)

      let contentMin = minimumContentSize(for: targetContentSize)

      DispatchQueue.main.async {
        window.setFrame(frame, display: true, animate: true)
        window.contentAspectRatio = targetContentSize
        window.contentMinSize = contentMin
      }
    }

    // MARK: NSWindowDelegate

    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
      // Maintain aspect based on the actual layout area (contentLayoutRect),
      // which excludes the titlebar/toolbar. Compute height from width so the
      // visible content keeps the intended aspect without letterboxing.
      let titlebar = titlebarHeight(for: sender)
      let aspect = max(currentAspect, 0.0001)
      let newHeight = titlebar + (frameSize.width / aspect)
      // Respect minimums driven by contentMinSize via AppKit; we simply shape
      // the proposed size to the correct relationship here.
      return NSSize(width: frameSize.width, height: newHeight)
    }

    func windowDidBecomeMain(_ notification: Notification) {
      guard let window else { return }
      if let existing = Self.restorableWindow, existing !== window {
        existing.isRestorable = false
      }
      window.isRestorable = true
      Self.restorableWindow = window
    }

    func windowWillClose(_ notification: Notification) {
      guard let window else { return }
      if Self.restorableWindow === window {
        Self.restorableWindow = nil
      }
    }

    // MARK: Geometry Helpers

    /// Current titlebar height for a window (frame minus content layout).
    private func titlebarHeight(for window: NSWindow) -> CGFloat {
      window.frame.height - window.contentLayoutRect.height
    }

    /// Build a window frame for a given content size, preserving origin and
    /// matching the window's contentLayoutRect so the visible area (excluding
    /// titlebar/toolbar) equals `contentSize`.
    private func frameFor(window: NSWindow, contentSize: CGSize) -> NSRect {
      let titlebar = titlebarHeight(for: window)
      let newHeight = contentSize.height + titlebar
      let top = window.frame.maxY
      return NSRect(
        x: window.frame.origin.x,
        y: top - newHeight,
        width: contentSize.width,
        height: newHeight
      )
    }

    // MARK: Sizing Helpers

    /// Compute a content size for media, downscaling by density if present and
    /// ensuring the smaller edge is at least `minimumEdge`.
    private func scaledContentSize(for display: DisplayInfo) -> CGSize {
      var width = display.size.width
      var height = display.size.height
      if let density = display.densityScale, density > 0 {
        width /= density
        height /= density
      }
      let scale = max(minimumEdge / width, minimumEdge / height, 1)
      width *= scale
      height *= scale
      return CGSize(width: width, height: height)
    }

    /// Minimum content size that keeps the smaller edge at least
    /// `minimumEdge`, preserving aspect ratio.
    private func minimumContentSize(for contentSize: CGSize) -> CGSize {
      // Minimum content size keeps the smaller edge at least `minimumEdge`,
      // preserving aspect ratio. Do not clamp the scale to 1; the minimum may
      // be smaller than the current content size for large media.
      let scale = max(minimumEdge / contentSize.width, minimumEdge / contentSize.height)
      return CGSize(width: contentSize.width * scale, height: contentSize.height * scale)
    }
  }
}
