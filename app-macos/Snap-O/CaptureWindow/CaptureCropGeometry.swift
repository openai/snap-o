import CoreGraphics

enum CaptureCropHandle: CaseIterable {
  case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

  var position: CGPoint {
    switch self {
    case .topLeft: CGPoint(x: 0, y: 0)
    case .top: CGPoint(x: 0.5, y: 0)
    case .topRight: CGPoint(x: 1, y: 0)
    case .right: CGPoint(x: 1, y: 0.5)
    case .bottomRight: CGPoint(x: 1, y: 1)
    case .bottom: CGPoint(x: 0.5, y: 1)
    case .bottomLeft: CGPoint(x: 0, y: 1)
    case .left: CGPoint(x: 0, y: 0.5)
    }
  }
}

enum CaptureCropGeometry {
  static let fullImage = CGRect(x: 0, y: 0, width: 1, height: 1)

  static func frame(for crop: CGRect, in image: CGRect) -> CGRect {
    CGRect(
      x: image.minX + crop.minX * image.width,
      y: image.minY + crop.minY * image.height,
      width: crop.width * image.width,
      height: crop.height * image.height
    )
  }

  static func moving(_ crop: CGRect, by delta: CGSize) -> CGRect {
    CGRect(
      x: min(max(crop.minX + delta.width, 0), 1 - crop.width),
      y: min(max(crop.minY + delta.height, 0), 1 - crop.height),
      width: crop.width,
      height: crop.height
    )
  }

  static func resizing(_ crop: CGRect, handle: CaptureCropHandle, by delta: CGSize, minimum: CGSize) -> CGRect {
    var left = crop.minX
    var right = crop.maxX
    var top = crop.minY
    var bottom = crop.maxY
    let position = handle.position
    if position.x == 0 { left = min(max(left + delta.width, 0), right - minimum.width) }
    if position.x == 1 { right = max(min(right + delta.width, 1), left + minimum.width) }
    if position.y == 0 { top = min(max(top + delta.height, 0), bottom - minimum.height) }
    if position.y == 1 { bottom = max(min(bottom + delta.height, 1), top + minimum.height) }
    return CGRect(x: left, y: top, width: right - left, height: bottom - top)
  }
}
