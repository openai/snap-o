import CoreGraphics

struct WorkspacePaneWidths: Equatable {
  let capture: CGFloat
  let tool: CGFloat
}

struct WorkspaceLayoutTransition: Equatable {
  enum Pane: Equatable {
    case capture
    case tool
  }

  let pane: Pane
  let toLayout: WorkspaceLayout
  let initialWindowWidth: CGFloat
  let finalWindowWidth: CGFloat
  let initialPanes: WorkspacePaneWidths
  let finalPanes: WorkspacePaneWidths

  func progress(windowWidth: CGFloat) -> CGFloat {
    let distance = finalWindowWidth - initialWindowWidth
    guard abs(distance) > 0.5 else { return 1 }
    return min(max((windowWidth - initialWindowWidth) / distance, 0), 1)
  }
}

struct WorkspacePanePresentation {
  let layout: WorkspaceLayout
  let captureWidth: CGFloat
  let toolWidth: CGFloat
  let captureVisibleWidth: CGFloat
  let toolVisibleWidth: CGFloat
  let transitioningPane: WorkspaceLayoutTransition.Pane?
  let dividerX: CGFloat?

  init(
    layout: WorkspaceLayout, windowWidth: CGFloat, preferredCaptureWidth: CGFloat,
    captureAspectRatio: CGFloat?, transition: WorkspaceLayoutTransition? = nil
  ) {
    transitioningPane = transition?.pane
    if let transition {
      self.layout = .both
      let progress = transition.progress(windowWidth: windowWidth)
      let visibility = transition.toLayout == .both ? progress : 1 - progress
      captureWidth = transition.initialPanes.capture + (transition.finalPanes.capture - transition.initialPanes.capture) * progress
      toolWidth = transition.initialPanes.tool + (transition.finalPanes.tool - transition.initialPanes.tool) * progress
      captureVisibleWidth = transition.pane == .capture ? captureWidth * visibility : captureWidth
      toolVisibleWidth = transition.pane == .tool ? toolWidth * visibility : toolWidth
    } else {
      self.layout = layout
      switch layout {
      case .capture:
        captureWidth = windowWidth
        toolWidth = 0
      case .tool:
        captureWidth = 0
        toolWidth = windowWidth
      case .both:
        captureWidth = WorkspaceLayout.constrainedCapturePaneWidth(
          preferredCaptureWidth, totalWidth: windowWidth, aspectRatio: captureAspectRatio
        )
        toolWidth = max(windowWidth - captureWidth - WorkspaceLayout.dividerWidth, 0)
      }
      captureVisibleWidth = captureWidth
      toolVisibleWidth = toolWidth
    }

    if self.layout == .both {
      dividerX = transitioningPane == .capture ? max(windowWidth - toolWidth - WorkspaceLayout.dividerWidth, 0) : captureWidth
    } else {
      dividerX = nil
    }
  }

  func zIndex(for pane: WorkspaceLayoutTransition.Pane) -> Double {
    guard let transitioningPane else { return 0 }
    return transitioningPane == pane ? 0 : 1
  }
}

enum WorkspaceLayoutPresentationEvent {
  case transitionWillBegin(WorkspaceLayoutTransition)
  case layoutDidApply(WorkspaceLayout)
}
