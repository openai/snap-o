import Foundation

final class RecordingSession: @unchecked Sendable {
  let deviceID: String
  let remotePath: String
  let startedAt: Date
  let pid: Int32

  private let connection: ADBSocketConnection
  private let completionTask: Task<Void, Error>

  init(deviceID: String, remotePath: String, pid: Int32, connection: ADBSocketConnection, startedAt: Date) {
    self.deviceID = deviceID
    self.remotePath = remotePath
    self.pid = pid
    self.connection = connection
    self.startedAt = startedAt

    completionTask = Task.detached(priority: .userInitiated) { [connection] in
      do {
        try connection.drainToEnd()
      } catch is CancellationError {
        return
      } catch {
        throw error
      }
    }
  }

  func waitUntilStopped() async throws {
    try await completionTask.value
  }

  func close() {
    completionTask.cancel()
    connection.close()
  }
}
