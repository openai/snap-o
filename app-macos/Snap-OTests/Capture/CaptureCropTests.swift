import AppKit
@testable import Snap_O
import Testing

struct CaptureCropTests {
  @Test
  func movingStopsAtEveryImageEdgeWithoutResizing() {
    let crop = CGRect(x: 0.2, y: 0.3, width: 0.4, height: 0.5)
    let upperLeft = CaptureCropGeometry.moving(crop, by: CGSize(width: -2, height: -2))
    let lowerRight = CaptureCropGeometry.moving(crop, by: CGSize(width: 2, height: 2))
    #expect(upperLeft == CGRect(origin: .zero, size: crop.size))
    #expect(lowerRight == CGRect(x: 0.6, y: 0.5, width: 0.4, height: 0.5))
    #expect(CaptureCropGeometry.moving(CaptureCropGeometry.fullImage, by: CGSize(width: 1, height: 1))
      == CaptureCropGeometry.fullImage)
  }

  @Test
  func everyHandleStaysInsideImageAndCannotCrossOppositeEdge() {
    let crop = CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
    let minimum = CGSize(width: 0.1, height: 0.1)
    for handle in CaptureCropHandle.allCases {
      for delta in [CGSize(width: -2, height: -2), CGSize(width: 2, height: 2)] {
        let result = CaptureCropGeometry.resizing(crop, handle: handle, by: delta, minimum: minimum)
        #expect(result.minX >= 0 && result.minY >= 0 && result.maxX <= 1 && result.maxY <= 1)
        #expect(result.width >= 0.0999 && result.height >= 0.0999)
        if handle.position.x != 0 { #expect(result.minX == crop.minX) }
        if handle.position.x != 1 { #expect(result.maxX == crop.maxX) }
        if handle.position.y != 0 { #expect(result.minY == crop.minY) }
        if handle.position.y != 1 { #expect(result.maxY == crop.maxY) }
      }
    }
  }

  @Test
  func cropTracksPreviewScaleAndOffset() {
    let crop = CGRect(x: 0.25, y: 0.1, width: 0.5, height: 0.8)
    let frame = CaptureCropGeometry.frame(for: crop, in: CGRect(x: 20, y: 60, width: 200, height: 400))
    #expect(frame == CGRect(x: 70, y: 100, width: 100, height: 320))
  }

  @Test @MainActor
  func dragUsesInitialCropAndCommandDragDoesNotMoveIt() throws {
    let view = CaptureCropOverlay.CropView(frame: CGRect(x: 0, y: 0, width: 400, height: 400))
    view.imageFrame = view.bounds
    view.crop = CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
    func event(_ type: NSEvent.EventType, x: CGFloat, command: Bool = false) throws -> NSEvent {
      try #require(NSEvent.mouseEvent(
        with: type,
        location: CGPoint(x: x, y: 200),
        modifierFlags: command ? .command : [],
        timestamp: 0,
        windowNumber: 0,
        context: nil,
        eventNumber: 0,
        clickCount: 1,
        pressure: 1
      ))
    }
    try view.mouseDown(with: event(.leftMouseDown, x: 200))
    try view.mouseDragged(with: event(.leftMouseDragged, x: 220))
    try view.mouseDragged(with: event(.leftMouseDragged, x: 240))
    #expect(abs(view.crop.minX - 0.35) < 0.0001)
    try view.mouseUp(with: event(.leftMouseUp, x: 240))
    let crop = view.crop
    try view.mouseDown(with: event(.leftMouseDown, x: 200, command: true))
    try view.mouseDragged(with: event(.leftMouseDragged, x: 201, command: true))
    #expect(view.crop == crop)
    var requestedFrames: [CGRect] = []
    view.makeDragItem = { frame in
      requestedFrames.append(frame)
      return nil
    }
    try view.mouseDragged(with: event(.leftMouseDragged, x: 220, command: true))
    try view.mouseDragged(with: event(.leftMouseDragged, x: 240, command: true))
    #expect(requestedFrames == [CaptureCropGeometry.frame(for: crop, in: view.imageFrame)])
    #expect(view.crop == crop)
    requestedFrames.removeAll()
    try view.mouseDown(with: event(.leftMouseDown, x: 20, command: true))
    try view.mouseDragged(with: event(.leftMouseDragged, x: 200, command: true))
    #expect(requestedFrames.isEmpty)
    #expect(view.crop == crop)
  }
}
