import AppKit
import SwiftUI

struct CaptureHistoryMouseNavigation: NSViewRepresentable {
  let isEnabled: Bool
  let goBack: () -> Void

  func makeNSView(context: Context) -> MouseNavigationView {
    MouseNavigationView()
  }

  func updateNSView(_ nsView: MouseNavigationView, context: Context) {
    nsView.isEnabled = isEnabled
    nsView.goBack = goBack
  }

  static func dismantleNSView(_ nsView: MouseNavigationView, coordinator: ()) {
    nsView.stopMonitoring()
  }

  @MainActor
  final class MouseNavigationView: NSView {
    var isEnabled = false
    var goBack: (() -> Void)?
    private var eventMonitor: Any?

    override func hitTest(_ point: NSPoint) -> NSView? {
      nil
    }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      stopMonitoring()
      guard window != nil else { return }
      eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .otherMouseDown) { [weak self] event in
        guard let self, isEnabled,
              let window, event.window === window,
              window.isKeyWindow, window.attachedSheet == nil,
              event.buttonNumber == 3 else { return event }
        goBack?()
        return nil
      }
    }

    func stopMonitoring() {
      if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
      eventMonitor = nil
    }
  }
}
