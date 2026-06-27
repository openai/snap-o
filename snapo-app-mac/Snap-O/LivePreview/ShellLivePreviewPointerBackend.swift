import Foundation
import SnapODeviceClient

struct ShellLivePreviewPointerBackend: LivePreviewPointerBackend {
  private static let maximumSendAttempts = 2

  private let adb: ADBService

  init(adb: ADBService) {
    self.adb = adb
  }

  func send(_ event: LivePreviewPointerEvent) async throws {
    let exec = await adb.exec()
    var lastError: Error?

    for attempt in 0 ..< Self.maximumSendAttempts {
      do {
        _ = try await exec.runShellString(
          deviceID: event.deviceID,
          command: event.shellCommand()
        )
        return
      } catch {
        if Task.isCancelled { throw CancellationError() }
        lastError = error
        if attempt + 1 < Self.maximumSendAttempts {
          await Task.yield()
        }
      }
    }

    throw lastError ?? ADBError.serverUnavailable("Failed to send pointer event")
  }
}

private extension LivePreviewPointerEvent {
  func shellCommand() -> String {
    let maximumX = max(0, Int(displaySize.width.rounded()) - 1)
    let maximumY = max(0, Int(displaySize.height.rounded()) - 1)
    let roundedX = min(max(0, Int(location.x.rounded())), maximumX)
    let roundedY = min(max(0, Int(location.y.rounded())), maximumY)

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
