import AppKit
@testable import Snap_O
import Testing

struct CaptureCropTests {
  @Test @MainActor
  func dragMeasuresFromInitialCrop() throws {
    let view = makeView()
    try view.mouseDown(with: event(.leftMouseDown, x: 200))
    try view.mouseDragged(with: event(.leftMouseDragged, x: 220))
    try view.mouseDragged(with: event(.leftMouseDragged, x: 240))
    #expect(abs(view.crop.minX - 0.35) < 0.0001)
  }

  @Test @MainActor
  func cornerArmEndResizesInsteadOfMovingCrop() throws {
    let view = makeView()
    try view.mouseDown(with: event(.leftMouseDown, x: 122, y: 302))
    try view.mouseDragged(with: event(.leftMouseDragged, x: 142, y: 282))
    #expect(view.crop == CGRect(x: 0.3, y: 0.3, width: 0.45, height: 0.45))
  }

  @Test @MainActor
  func verticalCornerArmEndResizesInsteadOfMovingCrop() throws {
    let view = makeView()
    try view.mouseDown(with: event(.leftMouseDown, x: 98, y: 278))
    try view.mouseDragged(with: event(.leftMouseDragged, x: 118, y: 258))
    #expect(view.crop == CGRect(x: 0.3, y: 0.3, width: 0.45, height: 0.45))
  }

  @Test @MainActor
  func sideAnchorEndResizesInsteadOfMovingCrop() throws {
    let view = makeView()
    try view.mouseDown(with: event(.leftMouseDown, x: 212, y: 302))
    try view.mouseDragged(with: event(.leftMouseDragged, x: 212, y: 282))
    #expect(view.crop == CGRect(x: 0.25, y: 0.3, width: 0.5, height: 0.45))
  }

  @Test @MainActor
  func uncroppedHandleDragStillResizes() throws {
    let view = makeView()
    view.crop = CaptureCropGeometry.fullImage
    try view.mouseDown(with: event(.leftMouseDown, x: 0))
    try view.mouseDragged(with: event(.leftMouseDragged, x: 40))
    #expect(view.crop == CGRect(x: 0.1, y: 0, width: 0.9, height: 1))
  }

  @Test(arguments: [true, false]) @MainActor
  func regularDragExportsOnlyWithoutCrop(isUncropped: Bool) throws {
    let view = makeView()
    if isUncropped { view.crop = CaptureCropGeometry.fullImage }
    var requests = 0
    view.makeDragItem = { _ in requests += 1
      return nil
    }
    try view.mouseDown(with: event(.leftMouseDown, x: 200))
    try view.mouseDragged(with: event(.leftMouseDragged, x: 240))
    #expect(requests == (isUncropped ? 1 : 0))
  }

  @Test @MainActor
  func pendingExportPreventsDraggingButStillAllowsResizing() throws {
    let view = makeView()
    view.crop = CaptureCropGeometry.fullImage
    view.allowsFileDrag = false
    var requests = 0
    view.makeDragItem = { _ in requests += 1
      return nil
    }
    try view.mouseDown(with: event(.leftMouseDown, x: 200))
    try view.mouseDragged(with: event(.leftMouseDragged, x: 240))
    try view.mouseUp(with: event(.leftMouseUp, x: 240))
    #expect(requests == 0)
    try view.mouseDown(with: event(.leftMouseDown, x: 0))
    try view.mouseDragged(with: event(.leftMouseDragged, x: 40))
    #expect(view.crop == CGRect(x: 0.1, y: 0, width: 0.9, height: 1))
  }

  @Test @MainActor
  func commandDragDoesNotMoveCrop() throws {
    let view = makeView()
    let original = view.crop
    try view.mouseDown(with: event(.leftMouseDown, x: 200, command: true))
    try view.mouseDragged(with: event(.leftMouseDragged, x: 201, command: true))
    #expect(view.crop == original)
  }

  @Test(arguments: [true, false]) @MainActor
  func commandDragExportsOnlyFromInsideCrop(startsInside: Bool) throws {
    let view = makeView()
    var requests = 0
    view.makeDragItem = { _ in requests += 1
      return nil
    }
    try view.mouseDown(with: event(.leftMouseDown, x: startsInside ? 200 : 20, command: true))
    try view.mouseDragged(with: event(.leftMouseDragged, x: 240, command: true))
    #expect(requests == (startsInside ? 1 : 0))
  }

  @Test(arguments: [CGFloat(200), 98]) @MainActor
  func escapeCancelsOnlyTheActiveCropGesture(startX: CGFloat) throws {
    let view = makeView()
    let window = makeWindow(view)
    defer {
      view.stopMonitoringEscape()
      window.contentView = nil
    }
    let original = view.crop
    var latestCrop = original
    view.cropChanged = { latestCrop = $0 }
    try view.mouseDown(with: event(.leftMouseDown, x: startX))
    try view.mouseDragged(with: event(.leftMouseDragged, x: startX + 40))
    #expect(view.crop != original)

    try NSApplication.shared.sendEvent(escape(in: window))

    #expect(view.crop == original)
    #expect(latestCrop == original)
    try view.mouseDragged(with: event(.leftMouseDragged, x: startX + 60))
    #expect(view.crop == original)
  }

  @Test @MainActor
  func escapeInAnotherWindowDoesNotCancelTheCrop() throws {
    let view = makeView()
    let window = makeWindow(view)
    let other = makeWindow(NSView())
    defer {
      view.stopMonitoringEscape()
      window.contentView = nil
      other.contentView = nil
    }
    try view.mouseDown(with: event(.leftMouseDown, x: 200))
    try view.mouseDragged(with: event(.leftMouseDragged, x: 240))
    let cropped = view.crop

    try NSApplication.shared.sendEvent(escape(in: other))

    #expect(view.crop == cropped)
    try view.mouseDragged(with: event(.leftMouseDragged, x: 260))
    #expect(view.crop != cropped)
  }

  @Test @MainActor
  func escapeAfterMouseUpPreservesTheCompletedCrop() throws {
    let view = makeView()
    let window = makeWindow(view)
    defer { window.contentView = nil }
    try view.mouseDown(with: event(.leftMouseDown, x: 200))
    try view.mouseDragged(with: event(.leftMouseDragged, x: 240))
    try view.mouseUp(with: event(.leftMouseUp, x: 240))
    let cropped = view.crop

    try NSApplication.shared.sendEvent(escape(in: window))

    #expect(view.crop == cropped)
  }

  @MainActor
  private func makeWindow(_ view: NSView) -> NSWindow {
    let window = NSWindow(
      contentRect: CGRect(x: 0, y: 0, width: 400, height: 400),
      styleMask: [.borderless], backing: .buffered, defer: false
    )
    window.contentView = view
    return window
  }

  @MainActor
  private func escape(in window: NSWindow) throws -> NSEvent {
    try #require(NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
      windowNumber: window.windowNumber, context: nil, characters: "\u{1B}",
      charactersIgnoringModifiers: "\u{1B}", isARepeat: false, keyCode: 53
    ))
  }

  @MainActor
  private func makeView() -> CaptureCropOverlay.CropView {
    let view = CaptureCropOverlay.CropView(frame: CGRect(x: 0, y: 0, width: 400, height: 400))
    view.imageFrame = view.bounds
    view.crop = CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
    return view
  }

  private func event(_ type: NSEvent.EventType, x: CGFloat, y: CGFloat = 200, command: Bool = false) throws -> NSEvent {
    try #require(NSEvent.mouseEvent(
      with: type, location: CGPoint(x: x, y: y), modifierFlags: command ? .command : [],
      timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
    ))
  }
}
