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
    private weak var window: NSWindow?

    private let minimumEdge: CGFloat
    private var lastMediaStamp: Date?
    private var currentAspect: CGFloat = 1

    private static let defaultContentSize = CGSize(width: 480, height: 480)
    private weak static var restorableWindow: NSWindow?

    init(minimumEdge: CGFloat) {
      self.minimumEdge = minimumEdge
    }

    func attach(to window: NSWindow) {
      guard self.window !== window else { return }
      self.window = window
      window.delegate = self
      window.setFrameAutosaveName("SnapOWindow")
      window.isRestorable = false
    }

    func sizeWindow(for media: Media) {
      guard lastMediaStamp != media.capturedAt else { return }
      lastMediaStamp = media.capturedAt

      let targetSize = scaledContentSize(for: media)
      currentAspect = targetSize.width / max(targetSize.height, 1)

      guard let window else { return }
      let titlebar = window.frame.height - window.contentLayoutRect.height
      let frame = NSRect(
        x: window.frame.origin.x,
        y: window.frame.origin.y,
        width: targetSize.width,
        height: targetSize.height + titlebar
      )

      let minSize = minimumContentSize(for: targetSize)

      DispatchQueue.main.async {
        window.setFrame(frame, display: true, animate: true)
        window.contentAspectRatio = targetSize
        window.contentMinSize = minSize
      }
    }

    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
      let titlebar = sender.frame.height - sender.contentLayoutRect.height
      var height = frameSize.height - titlebar
      if height <= 0 { return frameSize }
      var width = height * currentAspect

      if width < minimumEdge {
        width = minimumEdge
        height = width / currentAspect
      }
      if height < minimumEdge {
        height = minimumEdge
        width = height * currentAspect
      }

      return NSSize(width: width, height: height + titlebar)
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

    // MARK: Helpers

    private func scaledContentSize(for media: Media) -> CGSize {
      var width = media.width
      var height = media.height
      if let density = media.densityScale, density > 0 {
        width /= density
        height /= density
      }
      let scale = max(minimumEdge / width, minimumEdge / height, 1)
      width *= scale
      height *= scale
      return CGSize(width: width, height: height)
    }

    private func minimumContentSize(for contentSize: CGSize) -> CGSize {
      let scale = max(minimumEdge / contentSize.width, minimumEdge / contentSize.height, 1)
      return CGSize(width: contentSize.width * scale, height: contentSize.height * scale)
    }
  }
}
