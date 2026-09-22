import AppKit
import SwiftUI

struct CaptureHistoryThumbnailMenu: NSViewRepresentable {
  let canDelete: Bool
  let delete: () -> Void

  func makeNSView(context: Context) -> ThumbnailMenuView {
    ThumbnailMenuView()
  }

  func updateNSView(_ nsView: ThumbnailMenuView, context: Context) {
    nsView.canDelete = canDelete
    nsView.delete = delete
  }

  static func dismantleNSView(_ nsView: ThumbnailMenuView, coordinator: ()) {
    nsView.stopMonitoring()
  }

  @MainActor
  final class ThumbnailMenuView: NSView {
    var canDelete = false
    var delete: (() -> Void)?
    private var eventMonitor: Any?

    override func hitTest(_ point: NSPoint) -> NSView? {
      nil
    }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      stopMonitoring()
      guard window != nil else { return }
      // Intercept before NSToolbar substitutes its display-mode context menu.
      eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown]) { [weak self] event in
        guard let self, shouldOpenMenu(for: event) else { return event }
        NSMenu.popUpContextMenu(makeMenu(), with: event, for: self)
        return nil
      }
    }

    func shouldOpenMenu(for event: NSEvent) -> Bool {
      guard event.type == .rightMouseDown || (event.type == .leftMouseDown && event.modifierFlags.contains(.control)),
            let window, event.window === window, window.attachedSheet == nil,
            !isHiddenOrHasHiddenAncestor else { return false }
      let point = convert(event.locationInWindow, from: nil)
      return bounds.contains(point) && visibleRect.contains(point)
    }

    func makeMenu() -> NSMenu {
      let menu = NSMenu()
      menu.autoenablesItems = false
      let item = NSMenuItem(title: "Delete…", action: #selector(requestDeletion), keyEquivalent: "")
      item.target = self
      item.isEnabled = canDelete
      menu.addItem(item)
      return menu
    }

    @objc
    private func requestDeletion() {
      guard canDelete else { return }
      delete?()
    }

    func stopMonitoring() {
      if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
      eventMonitor = nil
    }
  }
}
