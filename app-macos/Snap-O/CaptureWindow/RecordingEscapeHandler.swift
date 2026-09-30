import AppKit
import SwiftUI

struct RecordingEscapeHandler: NSViewRepresentable {
  let isRecording: Bool
  let stopRecording: () -> Void

  func makeNSView(context: Context) -> EscapeView {
    EscapeView()
  }

  func updateNSView(_ view: EscapeView, context: Context) {
    view.isRecording = isRecording
    view.stopRecording = stopRecording
  }

  static func dismantleNSView(_ view: EscapeView, coordinator: ()) {
    view.stopMonitoring()
  }

  @MainActor
  final class EscapeView: NSView {
    var isRecording = false
    var stopRecording: (() -> Void)?
    private var eventMonitor: Any?

    override func hitTest(_ point: NSPoint) -> NSView? {
      nil
    }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      stopMonitoring()
      guard window != nil else { return }
      eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
        // Native preview and web views can consume Escape before SwiftUI shortcuts see it.
        self?.handleKeyDown(event) == true ? nil : event
      }
    }

    func handleKeyDown(_ event: NSEvent) -> Bool {
      guard isRecording, event.type == .keyDown, event.keyCode == 53,
            event.modifierFlags.isDisjoint(with: [.command, .control, .option, .shift]),
            let window, event.window === window, window.isKeyWindow,
            window.attachedSheet == nil, NSApp.modalWindow == nil,
            let stopRecording else { return false }
      // Let the first Escape cancel an in-progress text composition.
      if let input = window.firstResponder as? any NSTextInputClient, input.hasMarkedText() { return false }
      if !event.isARepeat { stopRecording() }
      return true
    }

    func stopMonitoring() {
      if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
      eventMonitor = nil
    }
  }
}
