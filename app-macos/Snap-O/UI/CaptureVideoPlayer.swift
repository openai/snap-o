@preconcurrency import AVKit
import SwiftUI

struct CaptureVideoPlayer: NSViewRepresentable {
  let player: AVPlayer?
  var onFocusChange: (Bool) -> Void = { _ in }
  var showsPlaybackControls = true
  var allowsVideoFrameAnalysis = true
  var togglePlayback: (() -> Void)?
  var stepFrame: ((Int) -> Void)?
  var playbackControlsFrame: CGRect?

  func makeNSView(context: Context) -> PlayerView {
    PlayerView()
  }

  func updateNSView(_ nsView: PlayerView, context: Context) {
    if nsView.player !== player { nsView.player = player }
    nsView.onFocusChange = onFocusChange
    let style: AVPlayerViewControlsStyle = showsPlaybackControls ? .inline : .none
    if nsView.controlsStyle != style { nsView.controlsStyle = style }
    if nsView.allowsVideoFrameAnalysis != allowsVideoFrameAnalysis { nsView.allowsVideoFrameAnalysis = allowsVideoFrameAnalysis }
    nsView.togglePlayback = togglePlayback
    nsView.stepFrame = stepFrame
    nsView.playbackControlsFrame = playbackControlsFrame
  }

  static func dismantleNSView(_ nsView: PlayerView, coordinator: ()) {
    nsView.stopMonitoring()
    nsView.player = nil
  }

  @MainActor
  final class PlayerView: AVPlayerView {
    var onFocusChange: (Bool) -> Void = { _ in }
    var togglePlayback: (() -> Void)?
    var stepFrame: ((Int) -> Void)?
    // The external controls' frame, relative to the video's top-left corner.
    var playbackControlsFrame: CGRect?
    private var eventMonitor: Any?
    private var ownsKeyboardFocus = false

    override var acceptsFirstResponder: Bool {
      true
    }

    override func keyDown(with event: NSEvent) {
      if !handlePlaybackKey(event) { super.keyDown(with: event) }
    }

    func handlePlaybackKey(_ event: NSEvent) -> Bool {
      guard event.modifierFlags.isDisjoint(with: [.command, .control, .option]) else { return false }
      if event.keyCode == 49, let togglePlayback { togglePlayback()
        return true
      }
      if event.keyCode == 123, let stepFrame { stepFrame(-1)
        return true
      }
      if event.keyCode == 124, let stepFrame { stepFrame(1)
        return true
      }
      return false
    }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      stopMonitoring()
      guard let window else { return }
      NotificationCenter.default.addObserver(
        self, selector: #selector(windowDidUpdate), name: NSWindow.didUpdateNotification, object: window
      )
      eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .keyDown]) { [weak self, weak window] event in
        guard let self, let window, event.window === window,
              window.attachedSheet == nil, !isHiddenOrHasHiddenAncestor else { return event }
        // AVPlayerView's internal responders can consume arrow keys before keyDown.
        if event.type == .keyDown {
          return containsKeyboardFocus && handlePlaybackKey(event) ? nil : event
        }
        let point = convert(event.locationInWindow, from: nil)
        var controls = playbackControlsFrame ?? .null
        if !isFlipped, !controls.isNull { controls.origin.y = bounds.maxY - controls.maxY }
        guard visibleRect.contains(point) || controls.contains(point) else { return event }
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
