import AppKit
import SwiftUI

/// Adjusts the window's level so Snap-O stays above other windows while a
/// recording or live preview session is active. When activity stops, the
/// window returns to the default level so it behaves like a normal document
/// window.
struct WindowLevelController: NSViewRepresentable {
  let shouldFloat: Bool

  func makeCoordinator() -> Coordinator {
    Coordinator()
  }

  func makeNSView(context: Context) -> NSView {
    let view = NSView()
    DispatchQueue.main.async {
      context.coordinator.updateWindowLevel(shouldFloat: shouldFloat, for: view.window)
    }
    return view
  }

  func updateNSView(_ nsView: NSView, context: Context) {
    DispatchQueue.main.async {
      context.coordinator.updateWindowLevel(shouldFloat: shouldFloat, for: nsView.window)
    }
  }

  // MARK: - Coordinator

  final class Coordinator {
    private var lastAppliedLevel: NSWindow.Level?

    func updateWindowLevel(shouldFloat: Bool, for window: NSWindow?) {
      guard let window else { return }
      DispatchQueue.main.async {
        window.level = shouldFloat ? .floating : .normal
      }
    }
  }
}
