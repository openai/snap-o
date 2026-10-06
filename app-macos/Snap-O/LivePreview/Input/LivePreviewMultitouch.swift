import CoreGraphics

struct LivePreviewMultitouch {
  private(set) var center = CGPoint(x: 0.5, y: 0.5)
  private var offset: CGPoint
  private var lastPointer: CGPoint

  init(pointer: CGPoint) {
    offset = CGPoint(x: pointer.x - 0.5, y: pointer.y - 0.5)
    lastPointer = pointer
  }

  var locations: [CGPoint] {
    [
      CGPoint(x: center.x + offset.x, y: center.y + offset.y),
      CGPoint(x: center.x - offset.x, y: center.y - offset.y)
    ]
  }

  mutating func move(to pointer: CGPoint, translating: Bool) {
    let delta = CGPoint(x: pointer.x - lastPointer.x, y: pointer.y - lastPointer.y)
    lastPointer = pointer
    if translating {
      center.x = min(1 - abs(offset.x), max(abs(offset.x), center.x + delta.x))
      center.y = min(1 - abs(offset.y), max(abs(offset.y), center.y + delta.y))
    } else {
      let limitX = min(center.x, 1 - center.x)
      let limitY = min(center.y, 1 - center.y)
      offset.x = min(limitX, max(-limitX, offset.x + delta.x))
      offset.y = min(limitY, max(-limitY, offset.y + delta.y))
    }
  }
}
