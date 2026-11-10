import CoreGraphics

struct WorkspaceLayoutChange {
  struct Snapshot {
    let frame: CGRect
    let desktopFrame: CGRect?
    let chromeHeight: CGFloat
    let minimumFrameSize: CGSize
    let rememberedPanes: WorkspacePaneWidths
    let previousDisplayAspectRatio: CGFloat?
    let windowedCaptureAspectRatio: CGFloat
  }

  let targetFrame: CGRect
  let paneTransition: WorkspaceLayoutTransition?
  let captureWidthToRemember: CGFloat?
  let toolWidthToRemember: CGFloat?

  init(from previousLayout: WorkspaceLayout, to layout: WorkspaceLayout, snapshot: Snapshot, displayAspectRatio: CGFloat?) {
    let frame = snapshot.frame
    let workspaceHeight = max(frame.height - snapshot.chromeHeight, 0)
    let minimumCaptureWidth = WorkspaceLayout.minimumCapturePaneWidth(aspectRatio: displayAspectRatio)
    let source = WorkspacePanePresentation(
      layout: previousLayout, windowWidth: frame.width, preferredCaptureWidth: snapshot.rememberedPanes.capture,
      captureAspectRatio: snapshot.previousDisplayAspectRatio
    )
    // A hidden pane starts at its remembered width when it slides into view.
    let initialPanes = WorkspacePaneWidths(
      capture: previousLayout.showsCapture ? source.captureWidth : max(snapshot.rememberedPanes.capture, minimumCaptureWidth),
      tool: previousLayout.showsTool ? source.toolWidth : snapshot.rememberedPanes.tool
    )
    let anchor: WorkspaceWindowAnchor
    let contentSize: CGSize
    let pane: WorkspaceLayoutTransition.Pane?
    var captureWidth: CGFloat?
    var toolWidth: CGFloat?

    switch (previousLayout, layout) {
    case (.capture, .both), (.tool, .both):
      pane = previousLayout == .capture ? .tool : .capture
      anchor = previousLayout == .capture ? .topLeft : .topRight
      contentSize = CGSize(
        width: initialPanes.capture + WorkspaceLayout.dividerWidth + initialPanes.tool,
        height: workspaceHeight
      )
      if previousLayout == .capture { captureWidth = initialPanes.capture }
    case (.both, .capture):
      pane = .tool
      anchor = .topLeft
      if let displayAspectRatio {
        let fitted = layout.fittedContentSize(
          in: CGSize(width: initialPanes.capture, height: max(workspaceHeight, 1)), captureAspectRatio: displayAspectRatio
        )
        let minimum = layout.minimumContentSize(captureAspectRatio: displayAspectRatio)
        contentSize = CGSize(width: max(fitted.width, minimum.width), height: max(fitted.height, minimum.height))
      } else {
        contentSize = CGSize(width: initialPanes.capture, height: workspaceHeight)
      }
      captureWidth = contentSize.width
    case (.both, .tool):
      pane = .capture
      anchor = .topRight
      contentSize = CGSize(width: initialPanes.tool, height: workspaceHeight)
      toolWidth = initialPanes.tool
    case (.capture, .tool):
      pane = nil
      anchor = .topLeft
      contentSize = CGSize(width: initialPanes.tool, height: workspaceHeight)
    case (.tool, .capture):
      pane = nil
      anchor = .topRight
      contentSize = CGSize(width: initialPanes.capture, height: initialPanes.capture / max(snapshot.windowedCaptureAspectRatio, 0.0001))
    case (.capture, .capture), (.tool, .tool), (.both, .both):
      targetFrame = frame
      paneTransition = nil
      captureWidthToRemember = nil
      toolWidthToRemember = nil
      return
    }

    captureWidthToRemember = captureWidth
    toolWidthToRemember = toolWidth
    let frameSize = CGSize(
      width: max(contentSize.width, snapshot.minimumFrameSize.width),
      height: max(contentSize.height + snapshot.chromeHeight, snapshot.minimumFrameSize.height)
    )
    targetFrame = WorkspaceLayout.constrainedWindowFrame(anchor.frame(with: frameSize, relativeTo: frame), to: snapshot.desktopFrame)

    if let pane {
      let destination = WorkspacePanePresentation(
        layout: layout, windowWidth: targetFrame.width, preferredCaptureWidth: initialPanes.capture,
        captureAspectRatio: displayAspectRatio
      )
      // The outgoing pane keeps its content width while its visible area shrinks.
      paneTransition = WorkspaceLayoutTransition(
        pane: pane, toLayout: layout, initialWindowWidth: frame.width, finalWindowWidth: targetFrame.width,
        initialPanes: initialPanes,
        finalPanes: WorkspacePaneWidths(
          capture: layout.showsCapture ? destination.captureWidth : initialPanes.capture,
          tool: layout.showsTool ? destination.toolWidth : initialPanes.tool
        )
      )
    } else {
      paneTransition = nil
    }
  }
}
