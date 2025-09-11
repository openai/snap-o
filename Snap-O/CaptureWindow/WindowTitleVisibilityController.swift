import AppKit
import SwiftUI

/// Hides the native NSWindow title so the custom SwiftUI title (in the toolbar)
/// is the only visible title content.
struct WindowTitleVisibilityController: NSViewRepresentable {
  func makeNSView(context: Context) -> NSView {
    let view = NSView()
    DispatchQueue.main.async {
      configure(window: view.window)
    }
    return view
  }

  func updateNSView(_ nsView: NSView, context: Context) {
    configure(window: nsView.window)
  }

  private func configure(window: NSWindow?) {
    guard let window else { return }
    window.titleVisibility = .hidden
    window.title = ""
  }
}
