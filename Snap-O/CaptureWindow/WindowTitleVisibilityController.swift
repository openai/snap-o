import AppKit
import SwiftUI

/// Hides the native NSWindow title so the custom SwiftUI title (in the toolbar)
/// is the only visible title content.
struct WindowTitleVisibilityController: NSViewRepresentable {
  func makeNSView(context: Context) -> NSView {
    let view = NSView()
    DispatchQueue.main.async {
      guard let window = view.window else { return }
      configure(window: window)
    }
    return view
  }

  func updateNSView(_ nsView: NSView, context: Context) {
    if let window = nsView.window { configure(window: window) }
  }

  private func configure(window: NSWindow) {
    window.titleVisibility = .hidden
    window.title = ""
  }
}

