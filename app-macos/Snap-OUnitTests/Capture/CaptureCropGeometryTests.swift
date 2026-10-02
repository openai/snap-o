import Foundation
import Testing

struct CaptureCropGeometryTests {
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
}
