import Dependencies
import Foundation

public final class RecordingSession: @unchecked Sendable {
  let target: DeviceTarget?
  public let deviceID: String
  public let remotePath: String
  public let startedAt: Date
  public let pid: Int32

  private let closeStream: @Sendable () -> Void
  private let completionTask: Task<Duration, Error>

  convenience init(
    deviceID: String,
    remotePath: String,
    pid: Int32,
    connection: ADBSocketConnection,
    startedAt: Date,
    target: DeviceTarget? = nil
  ) {
    self.init(deviceID: deviceID, remotePath: remotePath, pid: pid, startedAt: startedAt, target: target, drain: {
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        DispatchQueue.global(qos: .userInitiated).async {
          continuation.resume(with: Result { try connection.drainToEnd() })
        }
      }
    }, close: { connection.close() })
  }

  init(
    deviceID: String, remotePath: String, pid: Int32, startedAt: Date, target: DeviceTarget? = nil,
    drain: @escaping @Sendable () async throws -> Void, close: @escaping @Sendable () -> Void
  ) {
    self.target = target
    self.deviceID = deviceID
    self.remotePath = remotePath
    self.pid = pid
    closeStream = close
    self.startedAt = startedAt

    @Dependency(\.continuousClock)
    var sourceClock
    let clock = AnyClock(sourceClock)
    let started = clock.now
    completionTask = Task.detached(priority: .userInitiated) { [clock] in
      try await drain()
      return started.duration(to: clock.now)
    }
  }

  func recordedDuration() async throws -> Duration {
    try await completionTask.value
  }

  public func waitUntilStopped() async throws {
    _ = try await completionTask.value
  }

  func waitUntilStopped(
    timeout: Duration
  ) async throws {
    @Dependency(\.continuousClock)
    var clock
    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask {
        try await withTaskCancellationHandler {
          try await self.waitUntilStopped()
        } onCancel: {
          self.close()
        }
      }
      group.addTask { [clock] in
        try await clock.sleep(for: timeout)
        throw ADBError.requestTimedOut("Recording finalization timed out.")
      }
      defer { group.cancelAll() }
      try await group.next()
    }
  }

  public func close() {
    completionTask.cancel()
    closeStream()
  }
}
