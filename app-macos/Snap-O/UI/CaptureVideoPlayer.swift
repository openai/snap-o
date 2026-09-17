@preconcurrency import AVKit
import SwiftUI

struct CaptureVideoPlayer: NSViewRepresentable {
  let player: AVPlayer
  var onFocus: () -> Void = {}

  func makeNSView(context: Context) -> PlayerView {
    PlayerView()
  }

  func updateNSView(_ nsView: PlayerView, context: Context) {
    nsView.player = player
    nsView.onFocus = onFocus
  }

  static func dismantleNSView(_ nsView: PlayerView, coordinator: ()) {
    nsView.stopMonitoring()
    nsView.player = nil
  }

  @MainActor
  final class PlayerView: AVPlayerView {
    var onFocus: () -> Void = {}
    private var eventMonitor: Any?

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      stopMonitoring()
      guard window != nil else { return }
      eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
        guard let self, let window, event.window === window,
              window.attachedSheet == nil, !isHiddenOrHasHiddenAncestor,
              visibleRect.contains(convert(event.locationInWindow, from: nil)) else { return event }
        // SwiftUI's capture container can claim focus while handling the same click.
        DispatchQueue.main.async { [weak self, weak window] in
          guard let self, let window, self.window === window else { return }
          onFocus()
          var responder = window.firstResponder
          while let current = responder {
            if current === self { return }
            responder = current.nextResponder
          }
          window.makeFirstResponder(self)
        }
        return event
      }
    }

    func stopMonitoring() {
      if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
      eventMonitor = nil
    }
  }
}
