import AppKit
import SwiftUI

struct WorkspaceSplitterArea: NSViewRepresentable {
  let dragChanged: (CGFloat) -> Void
  let dragEnded: () -> Void
  let doubleClicked: () -> Void

  func makeNSView(context: Context) -> WorkspaceSplitterNSView {
    WorkspaceSplitterNSView(
      dragChanged: dragChanged,
      dragEnded: dragEnded,
      doubleClicked: doubleClicked
    )
  }

  func updateNSView(_ nsView: WorkspaceSplitterNSView, context: Context) {
    nsView.dragChanged = dragChanged
    nsView.dragEnded = dragEnded
    nsView.doubleClicked = doubleClicked
    nsView.window?.invalidateCursorRects(for: nsView)
  }
}

final class WorkspaceSplitterNSView: NSView {
  var dragChanged: (CGFloat) -> Void
  var dragEnded: () -> Void
  var doubleClicked: () -> Void

  private var dragOriginX: CGFloat?

  init(
    dragChanged: @escaping (CGFloat) -> Void,
    dragEnded: @escaping () -> Void,
    doubleClicked: @escaping () -> Void
  ) {
    self.dragChanged = dragChanged
    self.dragEnded = dragEnded
    self.doubleClicked = doubleClicked
    super.init(frame: .zero)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    nil
  }

  override func resetCursorRects() {
    super.resetCursorRects()
    addCursorRect(bounds, cursor: .resizeLeftRight)
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    window?.invalidateCursorRects(for: self)
  }

  override var mouseDownCanMoveWindow: Bool {
    false
  }

  override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
    true
  }

  override func mouseDown(with event: NSEvent) {
    if event.clickCount == 2 {
      dragOriginX = nil
      doubleClicked()
    } else {
      dragOriginX = event.locationInWindow.x
    }
  }

  override func mouseDragged(with event: NSEvent) {
    guard let dragOriginX else { return }
    dragChanged(event.locationInWindow.x - dragOriginX)
  }

  override func mouseUp(with event: NSEvent) {
    guard dragOriginX != nil else { return }
    dragOriginX = nil
    dragEnded()
  }
}
