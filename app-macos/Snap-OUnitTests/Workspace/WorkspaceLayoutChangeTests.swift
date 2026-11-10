import CoreGraphics
import Testing

struct WorkspaceLayoutChangeTests {
  struct Example {
    let from: WorkspaceLayout
    let to: WorkspaceLayout
    let roomyFrame: CGRect
    let narrowFrame: CGRect
  }

  static let examples = [
    Example(
      from: .capture,
      to: .both,
      roomyFrame: CGRect(x: 200, y: 100, width: 1101, height: 670),
      narrowFrame: CGRect(x: 0, y: 0, width: 850, height: 650)
    ),
    Example(
      from: .both,
      to: .capture,
      roomyFrame: CGRect(x: 200, y: 100, width: 300, height: 670),
      narrowFrame: CGRect(x: 0, y: 100, width: 240, height: 550)
    ),
    Example(
      from: .tool,
      to: .both,
      roomyFrame: CGRect(x: 229, y: 100, width: 1121, height: 670),
      narrowFrame: CGRect(x: 0, y: 0, width: 850, height: 650)
    ),
    Example(
      from: .both,
      to: .tool,
      roomyFrame: CGRect(x: 521, y: 100, width: 800, height: 670),
      narrowFrame: CGRect(x: 130, y: 0, width: 720, height: 650)
    ),
    Example(
      from: .capture,
      to: .tool,
      roomyFrame: CGRect(x: 200, y: 100, width: 800, height: 670),
      narrowFrame: CGRect(x: 50, y: 0, width: 800, height: 650)
    ),
    Example(
      from: .tool,
      to: .capture,
      roomyFrame: CGRect(x: 1030, y: 60, width: 320, height: 710),
      narrowFrame: CGRect(x: 530, y: 0, width: 320, height: 650)
    )
  ]

  @Test(arguments: examples, [false, true])
  func windowAndPanesUseTheSameDestination(example: Example, narrow: Bool) throws {
    let desktop = narrow ? CGRect(x: 0, y: 0, width: 850, height: 650) : CGRect(x: 0, y: 0, width: 2000, height: 1000)
    let initial = switch example.from {
    case .capture: CGRect(x: 200, y: 100, width: 300, height: 670)
    case .tool: CGRect(x: 550, y: 100, width: 800, height: 670)
    case .both: CGRect(x: 200, y: 100, width: 1121, height: 670)
    }
    let frame = WorkspaceLayout.constrainedWindowFrame(initial, to: desktop)
    let minimum = example.to.minimumContentSize(captureAspectRatio: 0.5)
    let snapshot = WorkspaceLayoutChange.Snapshot(
      frame: frame, desktopFrame: desktop, chromeHeight: 70,
      minimumFrameSize: CGSize(width: minimum.width, height: minimum.height + 70),
      rememberedPanes: WorkspacePaneWidths(capture: 320, tool: 800),
      previousDisplayAspectRatio: 0.5, windowedCaptureAspectRatio: 0.5
    )
    let change = WorkspaceLayoutChange(from: example.from, to: example.to, snapshot: snapshot, displayAspectRatio: 0.5)
    #expect(change.targetFrame == (narrow ? example.narrowFrame : example.roomyFrame))

    guard example.from == .both || example.to == .both else {
      #expect(change.paneTransition == nil)
      return
    }
    let transition = try #require(change.paneTransition)
    #expect(transition.finalWindowWidth == change.targetFrame.width)
    func presentation(at width: CGFloat, transition: WorkspaceLayoutTransition?) -> WorkspacePanePresentation {
      WorkspacePanePresentation(
        layout: example.to, windowWidth: width, preferredCaptureWidth: change.captureWidthToRemember ?? snapshot.rememberedPanes.capture,
        captureAspectRatio: 0.5, transition: transition
      )
    }
    let middle = presentation(at: (frame.width + change.targetFrame.width) / 2, transition: transition)
    switch transition.pane {
    case .capture:
      #expect(abs(middle.captureVisibleWidth - middle.captureWidth / 2) < 0.001)
      #expect(middle.toolVisibleWidth == middle.toolWidth)
    case .tool:
      #expect(abs(middle.toolVisibleWidth - middle.toolWidth / 2) < 0.001)
      #expect(middle.captureVisibleWidth == middle.captureWidth)
    }
    let end = presentation(at: change.targetFrame.width, transition: transition)
    let settled = presentation(at: change.targetFrame.width, transition: nil)
    #expect(abs(end.captureVisibleWidth - settled.captureVisibleWidth) < 0.001)
    #expect(abs(end.toolVisibleWidth - settled.toolVisibleWidth) < 0.001)
    if example.to == .both {
      let endDivider = try #require(end.dividerX)
      let settledDivider = try #require(settled.dividerX)
      #expect(abs(endDivider - settledDivider) < 0.001)
    }
  }

  @Test
  func revealingCaptureAtDesktopWidthSettlesWithoutAResize() throws {
    let frame = CGRect(x: 0, y: 0, width: 850, height: 650)
    let snapshot = WorkspaceLayoutChange.Snapshot(
      frame: frame, desktopFrame: frame, chromeHeight: 70, minimumFrameSize: CGSize(width: 981, height: 550),
      rememberedPanes: WorkspacePaneWidths(capture: 320, tool: 850),
      previousDisplayAspectRatio: 0.5, windowedCaptureAspectRatio: 0.5
    )
    let change = WorkspaceLayoutChange(from: .tool, to: .both, snapshot: snapshot, displayAspectRatio: 0.5)
    let transition = try #require(change.paneTransition)
    #expect(change.targetFrame == frame)
    #expect(transition.progress(windowWidth: frame.width) == 1)
    let panes = WorkspacePanePresentation(
      layout: .both, windowWidth: frame.width, preferredCaptureWidth: 320, captureAspectRatio: 0.5, transition: transition
    )
    #expect(panes.captureVisibleWidth == panes.captureWidth)
    #expect(panes.toolVisibleWidth == panes.toolWidth)
    #expect(abs(panes.captureVisibleWidth + WorkspaceLayout.dividerWidth + panes.toolVisibleWidth - frame.width) < 0.001)
  }

  @Test
  func rotationUsesTheOldAspectForTheSourceAndTheNewAspectForTheDestination() throws {
    let snapshot = WorkspaceLayoutChange.Snapshot(
      frame: CGRect(x: 0, y: 0, width: 1000, height: 550), desktopFrame: nil, chromeHeight: 70,
      minimumFrameSize: CGSize(width: 480, height: 310), rememberedPanes: WorkspacePaneWidths(capture: 320, tool: 720),
      previousDisplayAspectRatio: 0.5, windowedCaptureAspectRatio: 2
    )
    let change = WorkspaceLayoutChange(from: .both, to: .capture, snapshot: snapshot, displayAspectRatio: 2)
    let transition = try #require(change.paneTransition)
    #expect(transition.initialPanes.capture == 279)
    #expect(transition.finalPanes.capture == 480)
    #expect(change.targetFrame.size == CGSize(width: 480, height: 310))
  }

  @Test
  func unknownDisplayKeepsTheWorkspaceHeightWhenHidingTheTool() {
    let snapshot = WorkspaceLayoutChange.Snapshot(
      frame: CGRect(x: 20, y: 30, width: 1121, height: 600), desktopFrame: nil, chromeHeight: 70,
      minimumFrameSize: CGSize(width: 240, height: 310), rememberedPanes: WorkspacePaneWidths(capture: 320, tool: 800),
      previousDisplayAspectRatio: nil, windowedCaptureAspectRatio: 1
    )
    let change = WorkspaceLayoutChange(from: .both, to: .capture, snapshot: snapshot, displayAspectRatio: nil)
    #expect(change.targetFrame == CGRect(x: 20, y: 30, width: 320, height: 600))
    #expect(change.captureWidthToRemember == 320)
  }
}
