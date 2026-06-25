import AppKit
import Foundation
import SnapODeviceClient

/// Input source reported by the live-preview surface.
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
  private static let maximumSendAttempts = 2

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
    while !pendingEvents.isEmpty {
      let event = pendingEvents.removeFirst()
      do {
        try await send(event)
      } catch {
        SnapOLog.ui.error(
          "Failed to send pointer event: \(error.localizedDescription, privacy: .public)"
        )
      }
    }

    isFlushing = false

    if !pendingEvents.isEmpty {
      isFlushing = true
      await flushQueue()
    }
  }

  private func send(_ event: LivePreviewPointerEvent) async throws {
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
