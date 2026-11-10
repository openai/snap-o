import CoreGraphics
import Testing

struct WorkspaceWindowFitTests {
  @Test
  func portraitAndLandscapePreviewsUseTheLimitingDesktopDimension() {
    let available = CGSize(width: 1440, height: 800)
    #expect(WorkspaceLayout.capture.fittedContentSize(in: available, captureAspectRatio: 0.5) == CGSize(width: 400, height: 800))
    #expect(WorkspaceLayout.capture.fittedContentSize(in: available, captureAspectRatio: 2) == CGSize(width: 1440, height: 720))
  }

  @Test
  func toolLayoutsUseTheAvailableDesktopArea() {
    let available = CGSize(width: 1200, height: 800)
    for layout in [WorkspaceLayout.tool, .both] {
      #expect(layout.fittedContentSize(in: available, captureAspectRatio: 0.5) == available)
    }
  }

  @Test
  func allFourEdgesIncludeTheInsideAndOutsideOfTheBorder() {
    let size = CGSize(width: 320, height: 640)
    for offset: CGFloat in [-3, 0, 3] {
      #expect(WorkspaceWindowEdge(at: CGPoint(x: offset, y: 320), in: size) == .left)
      #expect(WorkspaceWindowEdge(at: CGPoint(x: size.width + offset, y: 320), in: size) == .right)
      #expect(WorkspaceWindowEdge(at: CGPoint(x: 160, y: size.height + offset), in: size) == .top)
      #expect(WorkspaceWindowEdge(at: CGPoint(x: 160, y: offset), in: size) == .bottom)
    }
  }

  @Test
  func cornersTitleBarAndContentKeepTheirOwnGestures() {
    let size = CGSize(width: 320, height: 640)
    let points = [
      CGPoint(x: 12, y: 320), CGPoint(x: 160, y: 628), CGPoint(x: 160, y: 12),
      CGPoint(x: 0, y: 10), CGPoint(x: 320, y: 630), CGPoint(x: 10, y: 640), CGPoint(x: 310, y: 0)
    ]
    for point in points {
      #expect(WorkspaceWindowEdge(at: point, in: size) == nil)
    }
  }

  @Test
  func eachEdgeGrowsFromItsOppositeEdge() {
    let frame = CGRect(x: -600, y: 125, width: 200, height: 100)
    let size = CGSize(width: 260, height: 180)
    #expect(WorkspaceWindowEdge.left.resizeAnchor.frame(with: size, relativeTo: frame).origin == CGPoint(x: -660, y: 45))
    #expect(WorkspaceWindowEdge.right.resizeAnchor.frame(with: size, relativeTo: frame).origin == CGPoint(x: -600, y: 45))
    #expect(WorkspaceWindowEdge.top.resizeAnchor.frame(with: size, relativeTo: frame).origin == CGPoint(x: -630, y: 125))
    #expect(WorkspaceWindowEdge.bottom.resizeAnchor.frame(with: size, relativeTo: frame).origin == CGPoint(x: -630, y: 45))
  }
}
