import Foundation

/// One deadline for a screenshot attempt, including retries and metadata reads.
enum ScreenshotDeadline {
  static let duration: Duration = .seconds(1)

  static func run<Value: Sendable>(
    _ operation: @escaping @Sendable () async throws -> Value
  ) async throws -> Value {
    try await withThrowingTaskGroup(of: Value.self) { group in
      group.addTask(operation: operation)
      group.addTask {
        try await Task.sleep(for: duration)
        throw ADBError.requestTimedOut("Screenshot capture timed out after 1 second")
      }
      defer { group.cancelAll() }
      guard let value = try await group.next() else { throw CancellationError() }
      return value
    }
  }
}
