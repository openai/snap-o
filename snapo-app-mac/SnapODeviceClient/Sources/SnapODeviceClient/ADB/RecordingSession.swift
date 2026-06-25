import Foundation

public final class RecordingSession: @unchecked Sendable {
  public let deviceID: String
  public let remotePath: String
  public let startedAt: Date
  public let pid: Int32

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

  public func waitUntilStopped() async throws {
    try await completionTask.value
  }

  public func close() {
    completionTask.cancel()
    connection.close()
  }
}
