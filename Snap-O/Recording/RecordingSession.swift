import Foundation

final class RecordingSession: @unchecked Sendable {
  let deviceID: String
  let remotePath: String
  let startedAt: Date
  private let connection: ADBSocketConnection

  init(deviceID: String, remotePath: String, connection: ADBSocketConnection, startedAt: Date) {
    self.deviceID = deviceID
    self.remotePath = remotePath
    self.connection = connection
    self.startedAt = startedAt
  }

  func stop() {
    connection.close()
  }
}
