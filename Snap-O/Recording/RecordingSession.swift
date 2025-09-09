import Foundation

final class RecordingSession: @unchecked Sendable {
  let deviceID: String
  let remotePath: String
  let startedAt: Date
  let pid: Int32
  private let connection: ADBSocketConnection
  private let completionTask: Task<Void, Error>

  init(deviceID: String, remotePath: String, pid: Int32, connection: ADBSocketConnection, completionTask: Task<Void, Error>, startedAt: Date) {
    self.deviceID = deviceID
    self.remotePath = remotePath
    self.pid = pid
    self.connection = connection
    self.completionTask = completionTask
    self.startedAt = startedAt
  }

  func waitUntilStopped() async throws {
    try await completionTask.value
  }

  func close() {
    connection.close()
  }
}
