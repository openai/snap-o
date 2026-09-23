import AppKit
import SwiftUI

struct CaptureHistoryGridBounds: PreferenceKey {
  struct Value {
    var items: [UUID: Anchor<CGRect>] = [:]
    var content: [Anchor<CGRect>] = []
  }

  static let defaultValue = Value()

  static func reduce(value: inout Value, nextValue: () -> Value) {
    let next = nextValue()
    value.items.merge(next.items) { _, new in new }
    value.content.append(contentsOf: next.content)
  }
}

struct CaptureHistoryRectangleSelection: NSViewRepresentable {
  let isEnabled: Bool
  let targets: [UUID: CGRect]
  let contentRects: [CGRect]
  let selectedIDs: Set<UUID>
  let select: (Set<UUID>) -> Void

  func makeNSView(context: Context) -> RectangleSelectionView {
    RectangleSelectionView()
  }

  func updateNSView(_ view: RectangleSelectionView, context: Context) {
    view.isEnabled = isEnabled
    view.targets = targets
    view.contentRects = contentRects
    view.selectedIDs = selectedIDs
    view.select = select
  }

  @MainActor
  final class RectangleSelectionView: NSView {
    var isEnabled = true {
      didSet { if !isEnabled { endSelection() } }
    }

    var targets: [UUID: CGRect] = [:]
    var contentRects: [CGRect] = []
    var selectedIDs: Set<UUID> = []
    var select: (Set<UUID>) -> Void = { _ in }
    private var origin: CGPoint?
    private var baseIDs: Set<UUID> = []
    private(set) var selectionRect: CGRect?

    override var isFlipped: Bool {
      true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
      guard let event = NSApp.currentEvent, event.type == .leftMouseDown,
            canStart(at: convert(point, from: superview), modifiers: event.modifierFlags) else { return nil }
      return self
    }

    func canStart(at point: CGPoint, modifiers: NSEvent.ModifierFlags) -> Bool {
      isEnabled && !isHiddenOrHasHiddenAncestor && window?.attachedSheet == nil
        && !modifiers.contains(.control) && visibleRect.contains(point)
        && !contentRects.contains { $0.contains(point) }
    }

    override func mouseDown(with event: NSEvent) {
      let point = convert(event.locationInWindow, from: nil)
      guard canStart(at: point, modifiers: event.modifierFlags) else { return }
      origin = point
      baseIDs = event.modifierFlags.isDisjoint(with: [.command, .shift]) ? [] : selectedIDs
      select(baseIDs)
    }

    override func mouseDragged(with event: NSEvent) {
      guard origin != nil else { return }
      _ = autoscroll(with: event)
      updateSelection(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
      if selectionRect != nil { updateSelection(at: convert(event.locationInWindow, from: nil)) }
      endSelection()
    }

    private func updateSelection(at point: CGPoint) {
      guard let origin else { return }
      let rect = CGRect(
        x: min(origin.x, point.x), y: min(origin.y, point.y),
        width: abs(point.x - origin.x), height: abs(point.y - origin.y)
      )
      selectionRect = rect
      let intersected = Set(targets.compactMap { rect.intersects($0.value) ? $0.key : nil })
      // Recompute from the initial selection so shrinking the rectangle removes newly covered items.
      select(baseIDs.union(intersected))
      needsDisplay = true
    }

    private func endSelection() {
      origin = nil
      selectionRect = nil
      baseIDs = []
      needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
      guard let selectionRect else { return }
      let path = NSBezierPath(rect: selectionRect)
      NSColor.controlAccentColor.withAlphaComponent(0.12).setFill()
      path.fill()
      NSColor.controlAccentColor.withAlphaComponent(0.8).setStroke()
      path.lineWidth = 1
      path.stroke()
    }
  }
}
