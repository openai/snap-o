import AppKit
@testable import Snap_O
import Testing

struct CaptureCropTests {
  @Test(arguments: [CGSize(width: -2, height: -2), CGSize(width: 2, height: 2)])
  func movingClampsToImageEdge(delta: CGSize) {
    let crop = CGRect(x: 0.2, y: 0.3, width: 0.4, height: 0.5)
    let expected = CGRect(x: delta.width < 0 ? 0 : 0.6, y: delta.height < 0 ? 0 : 0.5, width: 0.4, height: 0.5)
    #expect(CaptureCropGeometry.moving(crop, by: delta) == expected)
  }

  @Test(arguments: CaptureCropHandle.allCases)
  func resizingOutwardStopsAtImageBounds(handle: CaptureCropHandle) {
    let position = handle.position
    let result = CaptureCropGeometry.resizing(
      CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5), handle: handle,
      by: CGSize(width: (position.x - 0.5) * 4, height: (position.y - 0.5) * 4),
      minimum: CGSize(width: 0.1, height: 0.1)
    )
    #expect(CaptureCropGeometry.fullImage.contains(result))
  }

  @Test(arguments: CaptureCropHandle.allCases)
  func resizingInwardPreservesMinimumSize(handle: CaptureCropHandle) {
    let position = handle.position
    let result = CaptureCropGeometry.resizing(
      CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5), handle: handle,
      by: CGSize(width: (0.5 - position.x) * 4, height: (0.5 - position.y) * 4),
      minimum: CGSize(width: 0.1, height: 0.1)
    )
    #expect(result.width >= 0.0999 && result.height >= 0.0999)
  }

  @Test
  func cropTracksPreviewScaleAndOffset() {
    let crop = CGRect(x: 0.25, y: 0.1, width: 0.5, height: 0.8)
    let frame = CaptureCropGeometry.frame(for: crop, in: CGRect(x: 20, y: 60, width: 200, height: 400))
    #expect(frame == CGRect(x: 70, y: 100, width: 100, height: 320))
  }

  @Test @MainActor
  func dragMeasuresFromInitialCrop() throws {
    let view = makeView()
    try view.mouseDown(with: event(.leftMouseDown, x: 200))
    try view.mouseDragged(with: event(.leftMouseDragged, x: 220))
    try view.mouseDragged(with: event(.leftMouseDragged, x: 240))
    #expect(abs(view.crop.minX - 0.35) < 0.0001)
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

  @MainActor
  private func makeView() -> CaptureCropOverlay.CropView {
    let view = CaptureCropOverlay.CropView(frame: CGRect(x: 0, y: 0, width: 400, height: 400))
    view.imageFrame = view.bounds
    view.crop = CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
    return view
  }

  private func event(_ type: NSEvent.EventType, x: CGFloat, command: Bool = false) throws -> NSEvent {
    try #require(NSEvent.mouseEvent(
      with: type, location: CGPoint(x: x, y: 200), modifierFlags: command ? .command : [],
      timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
    ))
  }
}
