import CoreGraphics
@testable import Snap_O
import Testing

struct MultitouchTests {
  @Test func shiftTranslatesBothContacts() {
    var gesture = LivePreviewMultitouch(pointer: CGPoint(x: 0.625, y: 0.5))
    gesture.move(to: CGPoint(x: 0.375, y: 0.25), translating: true)
    #expect(gesture.locations == [CGPoint(x: 0.375, y: 0.25), CGPoint(x: 0.125, y: 0.25)])
  }

  @Test func releasingShiftDoesNotMoveContacts() {
    var gesture = LivePreviewMultitouch(pointer: CGPoint(x: 0.625, y: 0.5))
    gesture.move(to: CGPoint(x: 0.375, y: 0.25), translating: true)
    let before = gesture.locations
    gesture.move(to: CGPoint(x: 0.375, y: 0.25), translating: false)
    #expect(gesture.locations == before)
  }

  @Test func pinchStopsAtScreenEdge() {
    var gesture = LivePreviewMultitouch(pointer: CGPoint(x: 0.75, y: 0.75))
    gesture.move(to: CGPoint(x: 1, y: 1), translating: true)
    gesture.move(to: CGPoint(x: 2, y: 2), translating: false)
    #expect(gesture.locations == [CGPoint(x: 1, y: 1), CGPoint(x: 0.5, y: 0.5)])
  }
}
