import AppKit
import SwiftUI

@MainActor
enum WindowChromeMetrics {
  private static let standardWindowStyle: NSWindow.StyleMask = [
    .titled,
    .closable,
    .miniaturizable,
    .resizable
  ]

  static let titlebarHeight: CGFloat = {
    let contentRect = NSRect(x: 0, y: 0, width: 100, height: 100)
    let frameRect = NSWindow.frameRect(
      forContentRect: contentRect,
      styleMask: standardWindowStyle
    )
    return frameRect.height - contentRect.height
  }()

  static var totalToolbarHeight: CGFloat {
    titlebarHeight + CaptureToolbar.height
  }
}

/// Makes the AppKit titlebar transparent while retaining the real grouped
/// window buttons and their native behavior.
struct WindowChromeController: NSViewRepresentable {
  let title: String
  let dividerX: CGFloat?

  func makeCoordinator() -> Coordinator {
    Coordinator()
  }

  func makeNSView(context: Context) -> NSView {
    let view = NSView()
    context.coordinator.update(title: title, dividerX: dividerX)
    DispatchQueue.main.async {
      context.coordinator.attach(to: view.window)
    }
    return view
  }

  func updateNSView(_ nsView: NSView, context: Context) {
    context.coordinator.update(title: title, dividerX: dividerX)
    context.coordinator.attach(to: nsView.window)
  }

  @MainActor
  final class Coordinator: NSObject {
    private weak var window: NSWindow?
    private let dividerOverlay = WindowDividerOverlayView()
    private let titleOverlay = WindowTitleOverlayView()
    private var title = ""
    private var dividerX: CGFloat?

    func update(title: String, dividerX: CGFloat?) {
      self.title = title
      self.dividerX = dividerX
      dividerOverlay.dividerX = dividerX
      titleOverlay.title = title
      titleOverlay.networkLeadingX = dividerX
    }

    func attach(to window: NSWindow?) {
      guard let window else { return }
      if self.window !== window {
        dividerOverlay.removeFromSuperview()
        titleOverlay.removeFromSuperview()
        self.window = window
        observeWindowUpdates(window)
      }
      applyChrome(to: window)
      installDividerOverlay(in: window)
    }

    private func applyChrome(to window: NSWindow) {
      window.title = title
      window.isMovableByWindowBackground = false
      window.collectionBehavior.insert(.fullScreenPrimary)
    }

    private func observeWindowUpdates(_ window: NSWindow) {
      for name in [
        NSWindow.didBecomeKeyNotification,
        NSWindow.didResignKeyNotification,
        NSWindow.didResizeNotification,
        NSWindow.didEnterFullScreenNotification,
        NSWindow.didExitFullScreenNotification,
        NSWindow.didUpdateNotification
      ] {
        NotificationCenter.default.addObserver(
          self,
          selector: #selector(windowChromeDidUpdate(_:)),
          name: name,
          object: window
        )
      }
    }

    @objc
    private func windowChromeDidUpdate(_ notification: Notification) {
      guard let window = notification.object as? NSWindow else { return }
      applyChrome(to: window)
      installDividerOverlay(in: window)
    }

    private func installDividerOverlay(in window: NSWindow) {
      guard let frameView = window.contentView?.superview else { return }
      dividerOverlay.dividerX = dividerX
      dividerOverlay.frame = frameView.bounds
      dividerOverlay.autoresizingMask = [.width, .height]
      frameView.addSubview(dividerOverlay, positioned: .above, relativeTo: nil)

      titleOverlay.title = title
      titleOverlay.networkLeadingX = dividerX
      titleOverlay.frame = frameView.bounds
      titleOverlay.autoresizingMask = [.width, .height]
      frameView.addSubview(titleOverlay, positioned: .above, relativeTo: nil)
    }
  }
}

private final class WindowTitleOverlayView: NSView {
  var title = "" {
    didSet {
      needsDisplay = true
    }
  }

  var networkLeadingX: CGFloat? {
    didSet {
      needsDisplay = true
    }
  }

  override var isFlipped: Bool {
    true
  }

  override var isOpaque: Bool {
    false
  }

  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    guard !title.isEmpty,
          let contentView = window?.contentView
    else {
      return
    }

    let contentLeft = overlayX(forContentX: contentView.bounds.minX, contentView: contentView)
    let contentRight = overlayX(forContentX: contentView.bounds.maxX, contentView: contentView)
    let centerX = networkLeadingX.map {
      (overlayX(forContentX: $0, contentView: contentView) + contentRight) / 2
    } ?? ((contentLeft + contentRight) / 2)

    let attributedTitle = NSAttributedString(
      string: title,
      attributes: [
        .font: NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .semibold),
        .foregroundColor: NSColor.labelColor
      ]
    )
    let titleSize = attributedTitle.size()
    attributedTitle.draw(
      at: NSPoint(
        x: centerX - (titleSize.width / 2),
        y: (WindowChromeMetrics.titlebarHeight - titleSize.height) / 2
      )
    )
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    nil
  }

  private func overlayX(forContentX contentX: CGFloat, contentView: NSView) -> CGFloat {
    let pointInWindow = contentView.convert(NSPoint(x: contentX, y: 0), to: nil)
    return convert(pointInWindow, from: nil).x
  }
}

private final class WindowDividerOverlayView: NSView {
  var dividerX: CGFloat? {
    didSet {
      needsDisplay = true
    }
  }

  override var isOpaque: Bool {
    false
  }

  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    guard let dividerX,
          let contentView = window?.contentView
    else {
      return
    }

    let scale = window?.backingScaleFactor ?? 2
    let width = 1 / scale
    let pointInWindow = contentView.convert(NSPoint(x: dividerX, y: 0), to: nil)
    let pointInOverlay = convert(pointInWindow, from: nil)
    let alignedX = (pointInOverlay.x * scale).rounded() / scale

    NSColor.labelColor.withAlphaComponent(0.18).setFill()
    NSRect(
      x: alignedX - (width / 2),
      y: 0,
      width: width,
      height: bounds.height
    ).fill()
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    nil
  }
}
