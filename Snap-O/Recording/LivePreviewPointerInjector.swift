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

  init(adb: ADBService) {
    self.adb = adb
  }

  func send(event: LivePreviewPointerCommand, to deviceID: String) async {
    do {
      _ = try await adb.exec().runShellCommand(deviceID: deviceID, command: event.shellCommand())
    } catch {
      SnapOLog.ui.error(
        "Failed to send pointer event: \(error.localizedDescription, privacy: .public)"
      )
    }
  }
}
