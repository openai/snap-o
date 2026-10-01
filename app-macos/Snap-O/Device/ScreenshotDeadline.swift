import Dependencies
import Foundation

/// One deadline for a screenshot attempt, including retries and metadata reads.
enum ScreenshotDeadline {
  static let duration: Duration = .seconds(2)

  static func run<Value: Sendable>(
    _ operation: @escaping @Sendable () async throws -> Value
  ) async throws -> Value {
    @Dependency(\.continuousClock)
    var clock
    return try await withThrowingTaskGroup(of: Value.self) { group in
      group.addTask(operation: operation)
      group.addTask { [clock] in
        try await clock.sleep(for: duration)
        throw ADBError.requestTimedOut("Screenshot capture timed out after 2 seconds")
      }
      defer { group.cancelAll() }
      guard let value = try await group.next() else { throw CancellationError() }
      return value
    }
  }
}
