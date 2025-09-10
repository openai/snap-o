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

struct LivePreviewPointerCommand {
  var action: LivePreviewPointerAction
  var source: LivePreviewPointerSource
  var location: CGPoint
  var pointerIdentifier: Int = 0
  var displayIdentifier: Int = 0

  func shellCommand() -> String {
    let roundedX = Int(location.x.rounded())
    let roundedY = Int(location.y.rounded())

    let components: [String] = [
      "input",
      source.rawValue,
      "-d",
      "\(displayIdentifier)",
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
  private var pendingEvents: [(command: LivePreviewPointerCommand, deviceID: String)] = []
  private var isFlushing = false

  init(adb: ADBService) {
    self.adb = adb
  }

  func send(event: LivePreviewPointerCommand, to deviceID: String) async {
    await enqueue(event, for: deviceID)
  }

  private func enqueue(_ event: LivePreviewPointerCommand, for deviceID: String) async {
    if event.action == .move {
      pendingEvents.removeAll { $0.deviceID == deviceID && $0.command.action == .move }
    }
    pendingEvents.append((event, deviceID))

    guard !isFlushing else { return }
    isFlushing = true
    Task { await flushQueue() }
  }

  private func flushQueue() async {
    while !pendingEvents.isEmpty {
      let (event, deviceID) = pendingEvents.removeFirst()

      do {
        _ = try await adb.exec().runShellCommand(deviceID: deviceID, command: event.shellCommand())
      } catch {
        SnapOLog.ui.error(
          "Failed to send pointer event: \(error.localizedDescription, privacy: .public)"
        )
        pendingEvents.removeAll(keepingCapacity: true)
      }
    }

    isFlushing = false

    if !pendingEvents.isEmpty {
      isFlushing = true
      await flushQueue()
    }
  }
}
