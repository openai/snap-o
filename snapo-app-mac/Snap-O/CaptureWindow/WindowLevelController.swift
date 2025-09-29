import AppKit
import SwiftUI

/// Adjusts the window's level so Snap-O stays above other windows while a
/// recording or live preview session is active. When activity stops, the
/// window returns to the default level so it behaves like a normal document
/// window.
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
