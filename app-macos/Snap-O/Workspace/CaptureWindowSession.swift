import AppKit
import Observation

/// Keeps previews and tools running when SwiftUI replaces the window content.
@Observable
@MainActor
final class CaptureWindowSession {
  let capture: CapturePaneSession
  let tools: ToolSession
  let workspace: WorkspaceLayoutController
  private(set) var isClosed = false

  @ObservationIgnored private var windowObservers: [NSObjectProtocol] = []
  @ObservationIgnored private var hasStarted = false
  @ObservationIgnored private var startupTask: Task<Void, Never>?
  @ObservationIgnored private var closeTask: Task<Void, Never>?

  init(capture: CapturePaneSession, tools: ToolSession, workspace: WorkspaceLayoutController) {
    self.capture = capture
    self.tools = tools
    self.workspace = workspace
  }

  func attach(to window: NSWindow) {
    guard !isClosed else { return }
    if windowObservers.isEmpty {
      let center = NotificationCenter.default
      windowObservers = [
        center.addObserver(forName: NSWindow.didUpdateNotification, object: window, queue: .main) { [self] _ in
          MainActor.assumeIsolated { startIfVisible(window) }
        },
        center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [self] _ in
          MainActor.assumeIsolated {
            removeWindowObservers()
            // SwiftUI closes and reuses its hidden launch window before showing it.
            if hasStarted { close() }
          }
        }
      ]
    }
    startIfVisible(window)
  }

  private func startIfVisible(_ window: NSWindow) {
    if window.isVisible { startIfNeeded() }
  }

  func startIfNeeded() {
    guard !hasStarted, !isClosed else { return }
    hasStarted = true
    updatePaneVisibility()
    startupTask = Task { [capture] in
      guard !Task.isCancelled else { return }
      await capture.start()
    }
  }

  private func removeWindowObservers() {
    for observer in windowObservers {
      NotificationCenter.default.removeObserver(observer)
    }
    windowObservers.removeAll()
  }

  func updatePaneVisibility() {
    guard !isClosed, hasStarted else { return }
    capture.setVisible(workspace.showsCapture)
    tools.setVisible(workspace.showsTool)
  }

  func perform(_ command: SnapOCommand) {
    guard !isClosed else { return }
    workspace.revealCapture()
    updatePaneVisibility()
    capture.enqueue(command)
  }

  func openDevice(_ request: DeviceOpenRequest?) {
    guard !isClosed else { return }
    if request != nil { workspace.revealCapture() }
    updatePaneVisibility()
    capture.openDevice(request)
  }

  @discardableResult
  func close() -> Task<Void, Never> {
    if let closeTask { return closeTask }
    isClosed = true
    removeWindowObservers()
    startupTask?.cancel()
    let task = Task {
      async let captureCleanup: Void = capture.close()
      async let toolCleanup: Void = tools.stop()
      await startupTask?.value
      await captureCleanup
      await toolCleanup
    }
    closeTask = task
    return task
  }

}
