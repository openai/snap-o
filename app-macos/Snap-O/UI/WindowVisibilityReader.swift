import AppKit
import SwiftUI

struct WindowVisibilityReader: NSViewRepresentable {
  let visibilityDidChange: (Bool) -> Void

  func makeNSView(context: Context) -> WindowVisibilityView {
    WindowVisibilityView(visibilityDidChange: visibilityDidChange)
  }

  func updateNSView(_ view: WindowVisibilityView, context: Context) {
    view.visibilityDidChange = visibilityDidChange
  }

  static func dismantleNSView(_ view: WindowVisibilityView, coordinator: Void) {
    view.stopObserving()
  }
}

@MainActor
final class WindowVisibilityView: NSView {
  var visibilityDidChange: (Bool) -> Void
  private weak var observedWindow: NSWindow?
  private var observers: [NSObjectProtocol] = []
  private(set) var pendingReport: Task<Void, Never>?
  private var lastVisibility: Bool?

  init(visibilityDidChange: @escaping (Bool) -> Void) {
    self.visibilityDidChange = visibilityDidChange
    super.init(frame: .zero)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { nil }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    stopObserving()
    observedWindow = window
    guard let window else { return }
    let center = NotificationCenter.default
    let notifications: [Notification.Name] = [
      NSWindow.didChangeOcclusionStateNotification,
      NSWindow.didMiniaturizeNotification,
      NSWindow.didDeminiaturizeNotification,
      NSWindow.didBecomeKeyNotification,
      NSWindow.didResignKeyNotification
    ]
    for name in notifications {
      observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated { self?.scheduleReport() }
      })
    }
    for name in [NSApplication.didHideNotification, NSApplication.didUnhideNotification] {
      observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated { self?.scheduleReport() }
      })
    }
    scheduleReport()
  }

  private func scheduleReport() {
    pendingReport?.cancel()
    // AppKit can notify while SwiftUI is replacing the view. Read the settled window state.
    pendingReport = Task { @MainActor [weak self] in
      guard !Task.isCancelled, let self, let window = observedWindow, self.window === window else { return }
      let visible = window.isVisible && !window.isMiniaturized && window.occlusionState.contains(.visible)
      guard visible != lastVisibility else { return }
      lastVisibility = visible
      visibilityDidChange(visible)
    }
  }

  func stopObserving() {
    pendingReport?.cancel()
    pendingReport = nil
    for observer in observers { NotificationCenter.default.removeObserver(observer) }
    observers.removeAll()
    observedWindow = nil
    lastVisibility = nil
  }
}
