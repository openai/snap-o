import AppKit
@testable import Snap_O
import Testing

@Suite(.serialized)
@MainActor
struct CaptureHistoryThumbnailMenuTests {
  @Test
  func routesOnlyContextClicksInsideVisibleThumbnail() throws {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
      styleMask: [.borderless], backing: .buffered, defer: false
    )
    let container = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
    let view = CaptureHistoryThumbnailMenu.ThumbnailMenuView(frame: NSRect(x: 20, y: 20, width: 40, height: 40))
    container.clipsToBounds = true
    window.contentView = container
    container.addSubview(view)
    defer {
      view.removeFromSuperview()
      window.contentView = nil
    }

    func event(
      _ type: NSEvent.EventType, at point: NSPoint = NSPoint(x: 30, y: 30),
      modifiers: NSEvent.ModifierFlags = []
    ) throws -> NSEvent {
      try #require(NSEvent.mouseEvent(
        with: type, location: point, modifierFlags: modifiers, timestamp: 0,
        windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
      ))
    }

    #expect(view.shouldOpenMenu(for: try event(.rightMouseDown)))
    #expect(view.shouldOpenMenu(for: try event(.leftMouseDown, modifiers: .control)))
    #expect(!view.shouldOpenMenu(for: try event(.leftMouseDown)))
    #expect(!view.shouldOpenMenu(for: try event(.leftMouseDragged)))
    #expect(!view.shouldOpenMenu(for: try event(.rightMouseDown, at: NSPoint(x: 80, y: 30))))
    #expect(view.hitTest(NSPoint(x: 30, y: 30)) == nil)

    container.isHidden = true
    #expect(!view.shouldOpenMenu(for: try event(.rightMouseDown)))
    container.isHidden = false

    // A scrolled thumbnail may extend beyond its visible container.
    container.setFrameSize(NSSize(width: 40, height: 100))
    #expect(!view.shouldOpenMenu(for: try event(.rightMouseDown, at: NSPoint(x: 50, y: 30))))
    view.removeFromSuperview()
    #expect(!view.shouldOpenMenu(for: try event(.rightMouseDown)))
  }

  @Test
  func deletionMenuUsesCurrentAvailabilityAndAction() throws {
    let view = CaptureHistoryThumbnailMenu.ThumbnailMenuView()
    var deletions = 0
    view.delete = { deletions += 1 }
    let disabledItem = try #require(view.makeMenu().items.first)
    #expect(disabledItem.title == "Delete…")
    #expect(!disabledItem.isEnabled)
    let action = try #require(disabledItem.action)
    _ = view.perform(action)
    #expect(deletions == 0)

    view.canDelete = true
    let menu = view.makeMenu()
    #expect(menu.items.count == 1)
    #expect(menu.items[0].isEnabled)
    #expect(menu.items[0].target === view)
    _ = view.perform(action)
    #expect(deletions == 1)
    view.delete = { deletions += 10 }
    _ = view.perform(action)
    #expect(deletions == 11)
  }
}
