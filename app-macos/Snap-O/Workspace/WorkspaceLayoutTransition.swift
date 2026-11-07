import CoreGraphics

struct WorkspaceLayoutTransition: Equatable {
  enum Pane: Equatable {
    case capture
    case tool
  }

  let pane: Pane
  let fromLayout: WorkspaceLayout
  let toLayout: WorkspaceLayout
  let initialWindowWidth: CGFloat
  let finalWindowWidth: CGFloat
  let initialCapturePaneWidth: CGFloat
  let finalCapturePaneWidth: CGFloat
  let initialToolPaneWidth: CGFloat
  let finalToolPaneWidth: CGFloat

  func progress(windowWidth: CGFloat) -> CGFloat {
    let distance = finalWindowWidth - initialWindowWidth
    guard abs(distance) > 0.5 else { return 1 }
    return min(max((windowWidth - initialWindowWidth) / distance, 0), 1)
  }

  func capturePaneWidth(windowWidth: CGFloat) -> CGFloat {
    let progress = progress(windowWidth: windowWidth)
    return initialCapturePaneWidth
      + ((finalCapturePaneWidth - initialCapturePaneWidth) * progress)
  }

  func toolPaneWidth(windowWidth: CGFloat) -> CGFloat {
    let progress = progress(windowWidth: windowWidth)
    return initialToolPaneWidth
      + ((finalToolPaneWidth - initialToolPaneWidth) * progress)
  }
}

enum WorkspaceLayoutPresentationEvent {
  case transitionWillBegin(WorkspaceLayoutTransition)
  case layoutDidApply(WorkspaceLayout)
}
