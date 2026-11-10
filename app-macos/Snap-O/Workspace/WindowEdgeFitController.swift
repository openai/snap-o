import AppKit

@MainActor
final class WindowEdgeFitController {
  private var monitor: Any?
  private(set) var isAnimating = false

  func startMonitoring(_ handleEvent: @escaping @MainActor (NSEvent) -> Bool) {
    guard monitor == nil else { return }
    // AppKit handles border double-clicks before the content view sees them.
    monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
      handleEvent(event) ? nil : event
    }
  }

  func stopMonitoring() {
    if let monitor { NSEvent.removeMonitor(monitor) }
    monitor = nil
  }

  func fit(
    on event: NSEvent, in window: NSWindow, layout: WorkspaceLayout, captureAspectRatio: CGFloat,
    completion: @escaping @MainActor () -> Void
  ) -> Bool {
    guard event.type == .leftMouseDown, event.clickCount == 2, event.window === window,
          event.modifierFlags.isDisjoint(with: [.command, .control, .option, .shift]),
          window.attachedSheet == nil, let desktop = window.screen?.visibleFrame,
          let edge = WorkspaceWindowEdge(at: event.locationInWindow, in: window.frame.size)
    else { return false }
    guard !isAnimating else { return true }

    let contentSize = layout.fittedContentSize(in: WindowChromeMetrics.workspaceSize(in: desktop), captureAspectRatio: captureAspectRatio)
    let frame = edge.resizeAnchor.frame(with: WindowChromeMetrics.sizeIncludingToolbar(contentSize), relativeTo: window.frame)
    let target = WorkspaceLayout.constrainedWindowFrame(frame, to: desktop, minimumWidth: window.minSize.width)
    isAnimating = true
    window.animateWorkspaceFrame(to: target) { [weak self] in
      guard let self else { return }
      isAnimating = false
      completion()
    }
    return true
  }
}
