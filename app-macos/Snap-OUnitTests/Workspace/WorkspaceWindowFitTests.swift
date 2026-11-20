import CoreGraphics
import Testing

struct WorkspaceWindowFitTests {
  private struct Drag {
    var current = CGSize(width: 300, height: 680)
    var aspectRatio: CGFloat = 0.5
    var resize = CaptureWindowResize()

    mutating func propose(width: CGFloat, height: CGFloat) -> CGSize {
      current = resize.frameSize(
        from: current, to: CGSize(width: width, height: height), aspectRatio: aspectRatio,
        chromeHeight: 80, desktop: CGSize(width: 1440, height: 900)
      )
      return current
    }
  }

  @Test
  func verticalDragTracksHeightAcrossUpdatesAndDirectionChanges() {
    var drag = Drag()
    #expect(drag.propose(width: 300, height: 680) == CGSize(width: 300, height: 680))
    #expect(drag.propose(width: 300, height: 741) == CGSize(width: 331, height: 741))
    #expect(drag.propose(width: 300, height: 760) == CGSize(width: 340, height: 760))
    #expect(drag.propose(width: 340, height: 660) == CGSize(width: 290, height: 660))
  }

  @Test
  func cornerDragKeepsUsingWidthWhenOnlyHeightChangesLater() {
    var drag = Drag()
    #expect(drag.propose(width: 320, height: 700) == CGSize(width: 320, height: 720))
    #expect(drag.propose(width: 320, height: 750) == CGSize(width: 320, height: 720))
  }

  @Test
  func verticalDragFromDesktopFillKeepsTheWindowWidthForAPortraitDevice() {
    var drag = Drag(current: CGSize(width: 1440, height: 900))
    #expect(drag.propose(width: 1440, height: 880) == CGSize(width: 1440, height: 880))
  }

  @Test
  func verticalDragStopsWideningALandscapeWindowAtTheDesktopWidth() {
    var drag = Drag(current: CGSize(width: 1200, height: 680), aspectRatio: 2)
    #expect(drag.propose(width: 1200, height: 810) == CGSize(width: 1440, height: 810))
    #expect(drag.propose(width: 1440, height: 790) == CGSize(width: 1420, height: 790))
  }

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
