@preconcurrency import AVKit
import SwiftUI

struct CaptureVideoPlayer: NSViewRepresentable {
  let player: AVPlayer
  var onFocusChange: (Bool) -> Void = { _ in }

  func makeNSView(context: Context) -> PlayerView {
    PlayerView()
  }

  func updateNSView(_ nsView: PlayerView, context: Context) {
    nsView.player = player
    nsView.onFocusChange = onFocusChange
  }

  static func dismantleNSView(_ nsView: PlayerView, coordinator: ()) {
    nsView.stopMonitoring()
    nsView.player = nil
  }

  @MainActor
  final class PlayerView: AVPlayerView {
    var onFocusChange: (Bool) -> Void = { _ in }
    private var eventMonitor: Any?
    private var ownsKeyboardFocus = false

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      stopMonitoring()
      guard let window else { return }
      NotificationCenter.default.addObserver(
        self, selector: #selector(windowDidUpdate), name: NSWindow.didUpdateNotification, object: window
      )
      eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self, weak window] event in
        guard let self, let window, event.window === window,
              window.attachedSheet == nil, !isHiddenOrHasHiddenAncestor,
              visibleRect.contains(convert(event.locationInWindow, from: nil)) else { return event }
        // SwiftUI's capture container can claim focus while handling the same click.
        DispatchQueue.main.async { [weak self, weak window] in
          guard let self, let window, self.window === window, eventMonitor != nil else { return }
          focusPlayer()
        }
        return event
      }
    }

    func focusPlayer() {
      guard let window else { return }
      if !containsKeyboardFocus { window.makeFirstResponder(self) }
      guard containsKeyboardFocus else { return }
      ownsKeyboardFocus = true
      onFocusChange(true)
    }

    private var containsKeyboardFocus: Bool {
      var responder = window?.firstResponder
      while let current = responder {
        if current === self { return true }
        responder = current.nextResponder
      }
      return false
    }

    @objc
    private func windowDidUpdate() {
      // Moving between player controls is not a loss of video focus.
      guard ownsKeyboardFocus, !containsKeyboardFocus else { return }
      ownsKeyboardFocus = false
      onFocusChange(false)
    }

    func stopMonitoring() {
      NotificationCenter.default.removeObserver(self, name: NSWindow.didUpdateNotification, object: nil)
      ownsKeyboardFocus = false
      if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
      eventMonitor = nil
    }
  }
}
