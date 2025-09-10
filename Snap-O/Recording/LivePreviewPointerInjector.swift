import AppKit
import Foundation

enum LivePreviewPointerSource: String {
  case touchscreen
  case mouse
}

enum LivePreviewPointerAction: String {
  case down = "DOWN"
  case up = "UP"
  case move = "MOVE"
  case cancel = "CANCEL"
}

struct LivePreviewPointerEvent {
  let deviceID: String
  let action: LivePreviewPointerAction
  let source: LivePreviewPointerSource
  let location: CGPoint

  func shellCommand() -> String {
    let roundedX = Int(location.x.rounded())
    let roundedY = Int(location.y.rounded())

    let components: [String] = [
      "input",
      source.rawValue,
      "motionevent",
      action.rawValue,
      "\(roundedX)",
      "\(roundedY)"
    ]

    return components.joined(separator: " ")
  }
}

actor LivePreviewPointerInjector {
  private let adb: ADBService
  private var pendingEvents: [LivePreviewPointerEvent] = []
  private var isFlushing = false

  init(adb: ADBService) {
    self.adb = adb
  }

  func enqueue(_ event: LivePreviewPointerEvent) async {
    if event.action == .move {
      pendingEvents.removeAll { $0.deviceID == event.deviceID && $0.action == .move }
    }
    pendingEvents.append(event)

    guard !isFlushing else { return }
    isFlushing = true
    Task { await flushQueue() }
  }

  private func flushQueue() async {
    guard let connection = try? await adb.exec().makeConnection() else {
      isFlushing = false
      return
    }
    while !pendingEvents.isEmpty {
      let event = pendingEvents.removeFirst()

      do {
        try connection.sendTransport(to: event.deviceID)
        try connection.sendShell(event.shellCommand())
      } catch {
        SnapOLog.ui.error(
          "Failed to send pointer event: \(error.localizedDescription, privacy: .public)"
        )
        pendingEvents.removeAll(keepingCapacity: true)
      }
    }
    connection.close()

    isFlushing = false

    if !pendingEvents.isEmpty {
      isFlushing = true
      await flushQueue()
    }
  }
}
