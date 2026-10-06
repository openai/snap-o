import Foundation

public extension ADBClient {
  func openApp(deviceID: String, packageName: String, androidUserID: Int) async throws {
    try await AppLaunchCommand.open(packageName: packageName, androidUserID: androidUserID) { command in
      try await runShellString(deviceID: deviceID, command: command)
    }
  }
}
