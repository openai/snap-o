import Clocks
import Dependencies
import DependenciesTestSupport
import Foundation
import Testing

@Suite(.timeLimit(.minutes(1)), .dependency(\.continuousClock, TestClock()))
struct ScreenshotDeadlineTests {
  @Dependency(\.continuousClock, as: TestClock<Duration>.self) private var clock

  @Test
  func completionCancelsDeadline() async throws {
    let result = try await ScreenshotDeadline.run { 42 }
    #expect(result == 42)
    try await clock.checkSuspension()
  }

  @Test
  func timeoutCancelsOperation() async throws {
    let operation = TestSuspension()
    let task = Task {
      try await ScreenshotDeadline.run {
        try await operation.wait()
      }
    }
    await operation.waitUntilStarted()
    await clock.advance(by: .milliseconds(1999))
    #expect(!operation.wasCancelled)
    await clock.advance(by: .milliseconds(1))
    do {
      try await task.value
      Issue.record("Expected screenshot timeout")
    } catch ADBError.requestTimedOut {}
    #expect(operation.wasCancelled)
  }

  @Test
  func cancellationCancelsOperationAndDeadline() async throws {
    let operation = TestSuspension()
    let task = Task {
      try await ScreenshotDeadline.run {
        try await operation.wait()
      }
    }
    await operation.waitUntilStarted()
    await #expect(throws: SuspensionError.self) { try await clock.checkSuspension() }
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(operation.wasCancelled)
    try await clock.checkSuspension()
  }
}
