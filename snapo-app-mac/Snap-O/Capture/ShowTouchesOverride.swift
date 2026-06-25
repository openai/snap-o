import Foundation

struct ShowTouchesOverride {
  let deviceID: String
  let originalValue: Bool?

  static func apply(
    deviceID: String,
    enabled: Bool,
    using adb: ADBService
  ) async -> ShowTouchesOverride {
    let exec = await adb.exec()
    let originalValue: Bool
    do {
      originalValue = try await exec.getShowTouches(deviceID: deviceID)
    } catch {
      logFailure(action: "read", deviceID: deviceID, error: error)
      return ShowTouchesOverride(deviceID: deviceID, originalValue: nil)
    }

    if originalValue != enabled {
      do {
        try await exec.setShowTouches(deviceID: deviceID, enabled: enabled)
      } catch {
        logFailure(action: "update", deviceID: deviceID, error: error)
      }
    }
    return ShowTouchesOverride(deviceID: deviceID, originalValue: originalValue)
  }

  func restore(using adb: ADBService) async {
    guard let originalValue else { return }
    let exec = await adb.exec()
    do {
      try await exec.setShowTouches(deviceID: deviceID, enabled: originalValue)
    } catch {
      Self.logFailure(action: "restore", deviceID: deviceID, error: error)
    }
  }

  private static func logFailure(
    action: String,
    deviceID: String,
    error: Error
  ) {
    SnapOLog.recording.error(
      """
      Failed to \(action) show touches for \(deviceID, privacy: .private):
      \(error.localizedDescription, privacy: .public)
      """
    )
  }
}
