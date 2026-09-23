import AppKit
@testable import Snap_O
import Testing

@Suite(.serialized)
@MainActor
struct CaptureHistoryRectangleSelectionTests {
  @Test
  func rectangleReplacesSelectionAndShrinksInBothDirections() throws {
    try withView { view, first, second in
      var selected: Set<UUID> = [second]
      view.selectedIDs = selected
      view.select = { selected = $0
        view.selectedIDs = $0
      }
      try view.mouseDown(with: event(.leftMouseDown, at: CGPoint(x: 0, y: 0), in: view))
      #expect(selected.isEmpty)
      try view.mouseDragged(with: event(.leftMouseDragged, at: CGPoint(x: 150, y: 70), in: view))
      #expect(selected == [first, second])
      try view.mouseDragged(with: event(.leftMouseDragged, at: CGPoint(x: 70, y: 70), in: view))
      #expect(selected == [first])
      try view.mouseUp(with: event(.leftMouseUp, at: CGPoint(x: 70, y: 70), in: view))
      #expect(view.selectionRect == nil)
      #expect(selected == [first])

      try view.mouseDown(with: event(.leftMouseDown, at: CGPoint(x: 160, y: 80), in: view))
      try view.mouseDragged(with: event(.leftMouseDragged, at: CGPoint(x: 90, y: 10), in: view))
      #expect(selected == [second])
      #expect(view.selectionRect == CGRect(x: 90, y: 10, width: 70, height: 70))
    }
  }

  @Test(arguments: [NSEvent.ModifierFlags.command, .shift, [.command, .shift]])
  func modifierDragPreservesTheStartingSelection(modifiers: NSEvent.ModifierFlags) throws {
    try withView { view, first, second in
      var selected: Set<UUID> = [first]
      view.selectedIDs = selected
      view.select = { selected = $0
        view.selectedIDs = $0
      }
      try view.mouseDown(with: event(.leftMouseDown, at: CGPoint(x: 160, y: 80), modifiers: modifiers, in: view))
      try view.mouseDragged(with: event(.leftMouseDragged, at: CGPoint(x: 90, y: 10), in: view))
      #expect(selected == [first, second])
      try view.mouseDragged(with: event(.leftMouseDragged, at: CGPoint(x: 150, y: 75), in: view))
      #expect(selected == [first])
      try view.mouseUp(with: event(.leftMouseUp, at: CGPoint(x: 150, y: 75), in: view))
      #expect(selected == [first])
    }
  }

  @Test
  func onlyBlankSpaceStartsSelection() {
    withView { view, _, _ in
      #expect(view.canStart(at: CGPoint(x: 0, y: 0), modifiers: []))
      #expect(!view.canStart(at: CGPoint(x: 30, y: 30), modifiers: []))
      #expect(!view.canStart(at: CGPoint(x: -10, y: 0), modifiers: []))
      #expect(!view.canStart(at: CGPoint(x: 0, y: 0), modifiers: .control))
      view.isEnabled = false
      #expect(!view.canStart(at: CGPoint(x: 0, y: 0), modifiers: []))
    }
  }

  @Test
  func paddingInsideAnItemCanStartRectangleSelection() throws {
    try withView { view, first, _ in
      view.contentRects = [CGRect(x: 30, y: 30, width: 10, height: 10), CGRect(x: 30, y: 50, width: 10, height: 5)]
      #expect(view.canStart(at: CGPoint(x: 25, y: 25), modifiers: []))
      #expect(!view.canStart(at: CGPoint(x: 35, y: 35), modifiers: []))
      #expect(!view.canStart(at: CGPoint(x: 35, y: 52), modifiers: []))
      var selected: Set<UUID> = []
      view.select = { selected = $0 }
      try view.mouseDown(with: event(.leftMouseDown, at: CGPoint(x: 25, y: 25), in: view))
      try view.mouseDragged(with: event(.leftMouseDragged, at: CGPoint(x: 70, y: 70), in: view))
      #expect(selected == [first])
    }
  }

  private func withView(
    _ body: (CaptureHistoryRectangleSelection.RectangleSelectionView, UUID, UUID) throws -> Void
  ) rethrows {
    let frame = NSRect(x: 0, y: 0, width: 300, height: 200)
    let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
    let view = CaptureHistoryRectangleSelection.RectangleSelectionView(frame: frame)
    window.contentView = view
    defer { view.select = { _ in }
      window.contentView = nil
    }
    let first = UUID()
    let second = UUID()
    view.targets = [first: CGRect(x: 20, y: 20, width: 40, height: 40), second: CGRect(x: 100, y: 20, width: 40, height: 40)]
    view.contentRects = Array(view.targets.values)
    try body(view, first, second)
  }

  private func event(
    _ type: NSEvent.EventType, at point: CGPoint, modifiers: NSEvent.ModifierFlags = [],
    in view: NSView
  ) throws -> NSEvent {
    let window = try #require(view.window)
    return try #require(NSEvent.mouseEvent(
      with: type, location: view.convert(point, to: nil), modifierFlags: modifiers, timestamp: 0,
      windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
    ))
  }
}
