import AppKit
import SwiftUI

/// Bridges SwiftUI and AppKit to keep a window sized to the current media
/// aspect ratio while enforcing a sensible minimum edge length. The first
/// window opens at 480×480 points; subsequent windows inherit the size of the
/// most recently active window. Only the focused window is marked restorable so
/// reopened sessions bring back that single window.
struct WindowSizingController: NSViewRepresentable {
  let currentMedia: Media?

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
    guard let media = currentMedia else { return }
    context.coordinator.sizeWindow(for: media)
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
    func sizeWindow(for media: Media) {
      guard lastMediaStamp != media.capturedAt else { return }
      lastMediaStamp = media.capturedAt

      let targetContentSize = scaledContentSize(for: media)
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
      // Avoid conflicting with AppKit's built-in handling of aspect ratio and
      // minimum sizing driven by `contentAspectRatio` and `contentMinSize`.
      // Returning the proposed size prevents visual jumping during drags.
      let titlebar = titlebarHeight(for: sender)
      if frameSize.height - titlebar <= 0 { return frameSize }
      return frameSize
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
    /// adding the titlebar height to the content height.
    private func frameFor(window: NSWindow, contentSize: CGSize) -> NSRect {
      let titlebar = titlebarHeight(for: window)
      return NSRect(
        x: window.frame.origin.x,
        y: window.frame.origin.y,
        width: contentSize.width,
        height: contentSize.height + titlebar
      )
    }

    // MARK: Sizing Helpers

    /// Compute a content size for media, downscaling by density if present and
    /// ensuring the smaller edge is at least `minimumEdge`.
    private func scaledContentSize(for media: Media) -> CGSize {
      var width = media.size.width
      var height = media.size.height
      if let density = media.densityScale, density > 0 {
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
