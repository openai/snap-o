import CoreGraphics

extension WorkspaceLayout {
  static let minimumCaptureEdge: CGFloat = 240
  static let minimumToolSize = CGSize(width: 720, height: 480)
  static let dividerWidth: CGFloat = 1

  func fittedContentSize(in availableSize: CGSize, captureAspectRatio: CGFloat) -> CGSize {
    guard self == .capture else { return availableSize }
    let aspect = max(captureAspectRatio, 0.0001)
    let width = min(availableSize.width, availableSize.height * aspect)
    return CGSize(width: width, height: width / aspect)
  }

  static func minimumCapturePaneWidth(aspectRatio: CGFloat?) -> CGFloat {
    max(minimumPreferredCaptureWidth, capture.minimumContentSize(captureAspectRatio: aspectRatio).width)
  }

  static func constrainedCapturePaneWidth(_ preferredWidth: CGFloat, totalWidth: CGFloat, aspectRatio: CGFloat?) -> CGFloat {
    let minimumCaptureWidth = minimumCapturePaneWidth(aspectRatio: aspectRatio)
    let availableWidth = max(totalWidth - dividerWidth, 0)
    let maximumCaptureWidth = availableWidth - minimumToolSize.width
    guard maximumCaptureWidth >= minimumCaptureWidth else {
      // A Split View tile can be narrower than the two panes' combined minimum widths.
      return availableWidth * minimumCaptureWidth / (minimumCaptureWidth + minimumToolSize.width)
    }
    return min(max(preferredWidth, minimumCaptureWidth), maximumCaptureWidth)
  }

  func minimumContentSize(captureAspectRatio: CGFloat?) -> CGSize {
    switch self {
    case .capture:
      guard let aspect = captureAspectRatio, aspect > 0 else {
        return CGSize(width: Self.minimumCaptureEdge, height: Self.minimumCaptureEdge)
      }
      return CGSize(width: Self.minimumCaptureEdge * max(aspect, 1), height: Self.minimumCaptureEdge * max(1 / aspect, 1))
    case .tool:
      return Self.minimumToolSize
    case .both:
      let captureWidth = Self.minimumCapturePaneWidth(aspectRatio: captureAspectRatio)
      let captureHeight = Self.capture.minimumContentSize(captureAspectRatio: captureAspectRatio).height
      return CGSize(
        width: captureWidth + Self.dividerWidth + Self.minimumToolSize.width,
        height: max(Self.minimumToolSize.height, captureHeight)
      )
    }
  }

  static func constrainedWindowFrame(_ frame: CGRect, to desktop: CGRect?, minimumWidth: CGFloat = 0) -> CGRect {
    guard let desktop else { return frame }
    let width = min(max(frame.width, minimumWidth), desktop.width)
    let height = min(frame.height, desktop.height)
    let x = min(max(frame.minX, desktop.minX), desktop.maxX - width)
    let y = min(max(frame.minY, desktop.minY), desktop.maxY - height)
    return CGRect(x: x, y: y, width: width, height: height)
  }
}

enum WorkspaceWindowEdge {
  case left
  case right
  case top
  case bottom

  init?(at point: CGPoint, in windowSize: CGSize) {
    let edgeWidth: CGFloat = 4
    let cornerInset: CGFloat = 24
    let alongSide = point.y >= cornerInset && point.y <= windowSize.height - cornerInset
    let alongTopOrBottom = point.x >= cornerInset && point.x <= windowSize.width - cornerInset
    if alongSide, abs(point.x) <= edgeWidth {
      self = .left
    } else if alongSide, abs(point.x - windowSize.width) <= edgeWidth {
      self = .right
    } else if alongTopOrBottom, abs(point.y - windowSize.height) <= edgeWidth {
      self = .top
    } else if alongTopOrBottom, abs(point.y) <= edgeWidth {
      self = .bottom
    } else {
      return nil
    }
  }

  var resizeAnchor: WorkspaceWindowAnchor {
    switch self {
    case .left: .topRight
    case .right: .topLeft
    case .top: .bottom
    case .bottom: .top
    }
  }
}

enum WorkspaceWindowAnchor {
  case topLeft, topRight, top, bottom

  func frame(with size: CGSize, relativeTo source: CGRect) -> CGRect {
    let x: CGFloat = switch self {
    case .topLeft: source.minX
    case .topRight: source.maxX - size.width
    case .top, .bottom: source.midX - size.width / 2
    }
    let y = self == .bottom ? source.minY : source.maxY - size.height
    return CGRect(origin: CGPoint(x: x, y: y), size: size)
  }
}
