import AppKit
import SwiftUI

struct CaptureHistoryInsertion: Equatable {
  let itemID: UUID
  let afterTarget: Bool
}

struct CaptureHistoryDropBounds: PreferenceKey {
  static let defaultValue: [UUID: Anchor<CGRect>] = [:]

  static func reduce(value: inout [UUID: Anchor<CGRect>], nextValue: () -> [UUID: Anchor<CGRect>]) {
    value.merge(nextValue()) { _, new in new }
  }
}

struct CaptureHistoryDropTarget: NSViewRepresentable {
  let sourceID: UUID?
  let targets: [UUID: CGRect]
  let updateHint: (CaptureHistoryInsertion?) -> Void
  let performDrop: (CaptureHistoryInsertion) -> Void

  func makeNSView(context: Context) -> CaptureHistoryDropView {
    let view = CaptureHistoryDropView()
    view.registerForDraggedTypes([.fileURL])
    return view
  }

  func updateNSView(_ nsView: CaptureHistoryDropView, context: Context) {
    nsView.sourceID = sourceID
    nsView.targets = targets
    nsView.updateHint = updateHint
    nsView.performDrop = performDrop
  }

  static func dismantleNSView(_ nsView: CaptureHistoryDropView, coordinator: ()) {
    nsView.unregisterDraggedTypes()
  }
}

@MainActor
final class CaptureHistoryDropView: NSView {
  var sourceID: UUID? {
    didSet {
      if sourceID != oldValue { insertion = nil }
    }
  }

  var targets: [UUID: CGRect] = [:]
  var updateHint: (CaptureHistoryInsertion?) -> Void = { _ in }
  var performDrop: (CaptureHistoryInsertion) -> Void = { _ in }
  private var insertion: CaptureHistoryInsertion?

  override var isFlipped: Bool {
    true
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    // Let the underlying SwiftUI button start clicks and drags.
    guard sourceID != nil, NSApp.currentEvent?.type != .leftMouseDown else { return nil }
    return super.hitTest(point)
  }

  override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
    updateDrag(sender)
  }

  override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
    updateDrag(sender)
  }

  override func draggingExited(_ sender: (any NSDraggingInfo)?) {
    updateHint(nil)
  }

  override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
    guard accepts(sender), insertion != nil else { return false }
    // The thumbnail grid animates the reorder; remove the floating preview immediately.
    sender.animatesToDestination = false
    return true
  }

  override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
    guard accepts(sender), let insertion else { return false }
    updateHint(nil)
    self.insertion = nil
    performDrop(insertion)
    return true
  }

  override func wantsPeriodicDraggingUpdates() -> Bool {
    false
  }

  private func accepts(_ sender: any NSDraggingInfo) -> Bool {
    sourceID != nil && sender.draggingSource != nil
  }

  private func updateDrag(_ sender: any NSDraggingInfo) -> NSDragOperation {
    guard accepts(sender) else {
      updateHint(nil)
      return []
    }
    let point = convert(sender.draggingLocation, from: nil)
    if let target = insertionTarget(at: point) {
      insertion = CaptureHistoryInsertion(itemID: target.key, afterTarget: point.x >= target.value.midX)
    }
    // Keep the last insertion point when the pointer moves into empty space.
    updateHint(insertion)
    guard insertion != nil else { return [] }
    return sender.draggingSourceOperationMask.contains(.move) ? .move : .copy
  }

  private func insertionTarget(at point: CGPoint) -> [UUID: CGRect].Element? {
    if let target = targets.first(where: { $0.key != sourceID && $0.value.contains(point) }) {
      return target
    }
    guard bounds.contains(point),
          let bottom = targets.values.map(\.maxY).max(), point.y >= bottom,
          let lastRowTop = targets.values.map(\.minY).max() else { return nil }
    // Extend the last row downward so horizontal movement still selects an insertion point.
    return targets
      .filter { $0.key != sourceID && abs($0.value.minY - lastRowTop) < 1 }
      .min {
        let leftDistance = abs($0.value.midX - point.x)
        let rightDistance = abs($1.value.midX - point.x)
        return leftDistance == rightDistance ? $0.value.minX < $1.value.minX : leftDistance < rightDistance
      }
  }
}
