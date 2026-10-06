import AppKit
import SwiftUI

/// Floats the recording window only until Stop is requested.
struct WindowLevelController: NSViewRepresentable {
  let shouldFloat: Bool

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
    window.level = shouldFloat ? .floating : .normal
  }
}
