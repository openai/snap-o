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
      try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
          continuation.resume(with: Result { try connection.drainToEnd() })
        }
      }
    }
  }

  public func waitUntilStopped() async throws {
    try await completionTask.value
  }

  func waitUntilStopped(timeout: Duration) async throws {
    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask {
        try await withTaskCancellationHandler {
          try await self.waitUntilStopped()
        } onCancel: {
          self.close()
        }
      }
      group.addTask {
        try await Task.sleep(for: timeout)
        throw ADBError.requestTimedOut("Recording finalization timed out.")
      }
      defer { group.cancelAll() }
      try await group.next()
    }
  }

  public func close() {
    completionTask.cancel()
    connection.close()
  }
}
