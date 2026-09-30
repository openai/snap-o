import AppKit
import SwiftUI

struct CaptureCropOverlay: NSViewRepresentable {
  let imageFrame: CGRect
  @Binding var crop: CGRect
  let isEnabled: Bool
  let makeDragItem: (CGRect) -> NSDraggingItem?

  func makeNSView(context: Context) -> CropView {
    CropView()
  }

  func updateNSView(_ view: CropView, context: Context) {
    view.imageFrame = imageFrame
    view.crop = crop
    view.isEnabled = isEnabled
    view.cropChanged = { crop = $0 }
    view.makeDragItem = makeDragItem
    view.needsDisplay = true
    view.window?.invalidateCursorRects(for: view)
  }

  final class CropView: NSView, NSDraggingSource {
    private static let handleOutlineWidth: CGFloat = 4
    private static let cornerArmLength: CGFloat = 24
    private static let sideHalfLength: CGFloat = 12

    var imageFrame = CGRect.zero
    var crop = CaptureCropGeometry.fullImage {
      didSet { updateHandleOpacity() }
    }

    var isEnabled = true
    var cropChanged: ((CGRect) -> Void)?
    var makeDragItem: ((CGRect) -> NSDraggingItem?)?
    private var origin: CGPoint?
    private var initialCrop = CaptureCropGeometry.fullImage
    private var activeHandle: CaptureCropHandle?
    private var isExporting = false
    private var targetHandleOpacity: CGFloat = 0.45
    @objc dynamic var handleOpacity: CGFloat = 0.45 {
      didSet { needsDisplay = true }
    }

    override static func defaultAnimation(forKey key: NSAnimatablePropertyKey) -> Any? {
      if key == "handleOpacity" { return CABasicAnimation() }
      return super.defaultAnimation(forKey: key)
    }

    private func updateHandleOpacity() {
      let target: CGFloat = crop == CaptureCropGeometry.fullImage ? 0.45 : 1
      guard target != targetHandleOpacity else { return }
      targetHandleOpacity = target
      NSAnimationContext.runAnimationGroup { context in
        context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.18
        context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        animator().handleOpacity = target
      }
    }

    override var isFlipped: Bool {
      true
    }

    private var cropFrame: CGRect {
      CaptureCropGeometry.frame(for: crop, in: imageFrame)
    }

    private func handlePoint(_ handle: CaptureCropHandle) -> CGPoint {
      let position = handle.position
      let offset = Self.handleOutlineWidth / 2
      let rect = cropFrame.insetBy(dx: -offset, dy: -offset)
      return CGPoint(x: rect.minX + position.x * rect.width, y: rect.minY + position.y * rect.height)
    }

    private func handle(at point: CGPoint) -> CaptureCropHandle? {
      CaptureCropHandle.allCases.first { handleRects($0).contains { $0.contains(point) } }
    }

    private func handleRects(_ handle: CaptureCropHandle) -> [CGRect] {
      let center = handlePoint(handle)
      let position = handle.position
      if position.x == 0.5 {
        return [CGRect(x: center.x - Self.sideHalfLength, y: center.y, width: Self.sideHalfLength * 2, height: 0)
          .insetBy(dx: -10, dy: -10)]
      }
      if position.y == 0.5 {
        return [CGRect(x: center.x, y: center.y - Self.sideHalfLength, width: 0, height: Self.sideHalfLength * 2)
          .insetBy(dx: -10, dy: -10)]
      }
      return [
        CGRect(
          x: center.x - (position.x == 1 ? Self.cornerArmLength : 0),
          y: center.y,
          width: Self.cornerArmLength,
          height: 0
        ),
        CGRect(
          x: center.x,
          y: center.y - (position.y == 1 ? Self.cornerArmLength : 0),
          width: 0,
          height: Self.cornerArmLength
        )
      ].map { $0.insetBy(dx: -10, dy: -10) }
    }

    override func resetCursorRects() {
      super.resetCursorRects()
      guard isEnabled else { return }
      for handle in CaptureCropHandle.allCases {
        for rect in handleRects(handle) {
          addCursorRect(rect.intersection(bounds), cursor: handle.resizeCursor)
        }
      }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
      guard isEnabled else { return nil }
      if NSApp.currentEvent?.type == .rightMouseDown || NSApp.currentEvent?.modifierFlags.contains(.control) == true {
        return nil
      }
      let local = convert(point, from: superview)
      guard imageFrame.contains(local) || handle(at: local) != nil else { return nil }
      if NSApp.currentEvent?.modifierFlags.contains(.command) == true {
        return cropFrame.contains(local) ? self : nil
      }
      if handle(at: local) != nil { return self }
      return cropFrame.contains(local) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
      let point = convert(event.locationInWindow, from: nil)
      let handle = handle(at: point)
      isExporting = event.modifierFlags.contains(.command)
        || (crop == CaptureCropGeometry.fullImage && handle == nil)
      guard !isExporting || cropFrame.contains(point) else {
        origin = nil
        return
      }
      origin = point
      initialCrop = crop
      activeHandle = handle
    }

    override func mouseDragged(with event: NSEvent) {
      guard let origin, imageFrame.width > 0, imageFrame.height > 0 else { return }
      let point = convert(event.locationInWindow, from: nil)
      if isExporting {
        guard hypot(point.x - origin.x, point.y - origin.y) >= 3 else { return }
        self.origin = nil
        guard let item = makeDragItem?(cropFrame) else {
          NSSound.beep()
          return
        }
        beginDraggingSession(with: [item], event: event, source: self)
        return
      }
      let delta = CGSize(
        width: (point.x - origin.x) / imageFrame.width,
        height: (point.y - origin.y) / imageFrame.height
      )
      if let activeHandle {
        activeHandle.resizeCursor.set()
        let minimum = CGSize(
          width: min(initialCrop.width, 24 / imageFrame.width),
          height: min(initialCrop.height, 24 / imageFrame.height)
        )
        crop = CaptureCropGeometry.resizing(initialCrop, handle: activeHandle, by: delta, minimum: minimum)
      } else {
        crop = CaptureCropGeometry.moving(initialCrop, by: delta)
      }
      cropChanged?(crop)
      needsDisplay = true
      window?.invalidateCursorRects(for: self)
    }

    override func mouseUp(with event: NSEvent) {
      origin = nil
      activeHandle = nil
      isExporting = false
      window?.invalidateCursorRects(for: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
      .copy
    }

    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool {
      true
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
      origin = nil
      activeHandle = nil
      isExporting = false
      window?.invalidateCursorRects(for: self)
    }

    override func draw(_ dirtyRect: NSRect) {
      let shade = NSBezierPath(rect: imageFrame)
      shade.append(NSBezierPath(rect: cropFrame))
      shade.windingRule = .evenOdd
      NSColor.black.withAlphaComponent(0.5).setFill()
      shade.fill()
      for handle in CaptureCropHandle.allCases {
        let point = handlePoint(handle)
        let position = handle.position
        let path = NSBezierPath()
        path.lineCapStyle = .round
        if position.x == 0.5 {
          path.move(to: CGPoint(x: point.x - Self.sideHalfLength, y: point.y))
          path.line(to: CGPoint(x: point.x + Self.sideHalfLength, y: point.y))
        } else if position.y == 0.5 {
          path.move(to: CGPoint(x: point.x, y: point.y - Self.sideHalfLength))
          path.line(to: CGPoint(x: point.x, y: point.y + Self.sideHalfLength))
        } else {
          let horizontal: CGFloat = position.x == 0 ? 1 : -1
          let vertical: CGFloat = position.y == 0 ? 1 : -1
          let end = CGPoint(x: point.x + horizontal * Self.cornerArmLength, y: point.y)
          path.move(to: CGPoint(x: point.x, y: point.y + vertical * Self.cornerArmLength))
          path.appendArc(from: point, to: end, radius: 2)
          path.line(to: end)
        }
        NSColor.black.withAlphaComponent(0.6 * handleOpacity).setStroke()
        path.lineWidth = Self.handleOutlineWidth
        path.stroke()
        NSColor.white.withAlphaComponent(handleOpacity).setStroke()
        path.lineWidth = 2
        path.stroke()
      }
    }
  }
}

private extension CaptureCropHandle {
  var resizeCursor: NSCursor {
    let position: NSCursor.FrameResizePosition = switch self {
    case .topLeft: .topLeft
    case .top: .top
    case .topRight: .topRight
    case .right: .right
    case .bottomRight: .bottomRight
    case .bottom: .bottom
    case .bottomLeft: .bottomLeft
    case .left: .left
    }
    return .frameResize(position: position, directions: .all)
  }
}
