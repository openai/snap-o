import AppKit
import Combine
import SwiftUI

struct WindowVisibilityReader: View {
  let visibilityDidChange: (Bool) -> Void

  @State private var windowID: ObjectIdentifier?

  var body: some View {
    WindowReader { window in
      windowID = window.map(ObjectIdentifier.init)
      visibilityDidChange(window.map(isVisible) ?? false)
    }
    .onReceive(NotificationCenter.default.publisher(for: NSWindow.didChangeOcclusionStateNotification)) {
      guard let window = $0.object as? NSWindow,
            ObjectIdentifier(window) == windowID else { return }
      visibilityDidChange(isVisible(window))
    }
  }

  private func isVisible(_ window: NSWindow) -> Bool {
    window.isVisible
      && !window.isMiniaturized
      && window.occlusionState.contains(.visible)
  }
}

private struct WindowReader: NSViewRepresentable {
  let windowDidChange: (NSWindow?) -> Void

  func makeNSView(context: Context) -> WindowReaderView {
    WindowReaderView(windowDidChange: windowDidChange)
  }

  func updateNSView(_ nsView: WindowReaderView, context: Context) {
    nsView.windowDidChange = windowDidChange
  }
}

@MainActor
private final class WindowReaderView: NSView {
  var windowDidChange: (NSWindow?) -> Void

  init(windowDidChange: @escaping (NSWindow?) -> Void) {
    self.windowDidChange = windowDidChange
    super.init(frame: .zero)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    windowDidChange(window)
  }
}
