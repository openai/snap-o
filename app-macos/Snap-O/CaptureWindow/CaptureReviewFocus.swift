import AppKit
import SwiftUI

struct CaptureReviewFocus: NSViewRepresentable {
  let onExit: () -> Void

  func makeNSView(context: Context) -> FocusView {
    FocusView()
  }

  func updateNSView(_ view: FocusView, context: Context) {
    view.onExit = onExit
  }

  final class FocusView: NSView {
    var onExit: (() -> Void)?

    override var acceptsFirstResponder: Bool {
      true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
      nil
    }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      guard let window else { return }
      // Each new review needs a responder after SwiftUI attaches its view hierarchy.
      DispatchQueue.main.async { [weak self, weak window] in
        guard let self, let window, self.window === window, window.attachedSheet == nil else { return }
        window.makeFirstResponder(self)
      }
    }

    override func keyDown(with event: NSEvent) {
      guard event.keyCode == 53 else {
        super.keyDown(with: event)
        return
      }
      onExit?()
    }
  }
}
