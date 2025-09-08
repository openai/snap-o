import AppKit
import Foundation

enum LivePreviewPointerSource: String {
  case touchscreen = "touchscreen"
  case mouse = "mouse"
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

  func adbArguments(deviceID: String) -> [String] {
    let roundedX = Int(location.x.rounded())
    let roundedY = Int(location.y.rounded())

    let arguments: [String] = [
      "-s", deviceID,
      "shell", "input",
      "\(source.rawValue)",
      "-d", "\(displayIdentifier)",
      "motionevent",
      "\(action.rawValue)",
      "\(roundedX)",
      "\(roundedY)"
    ]

    return arguments
  }
}

actor LivePreviewPointerInjector {
  private let adb: ADBService

  init(adb: ADBService) {
    self.adb = adb
  }

  func send(event: LivePreviewPointerCommand, to deviceID: String) async {
    do {
      let exec = try await adb.exec()
      _ = try await exec.runString(event.adbArguments(deviceID: deviceID))
    } catch {
      SnapOLog.ui.error(
        "Failed to send pointer event: \(error.localizedDescription, privacy: .public)"
      )
    }
  }
}
