import Foundation
@testable import Snap_O
import Testing

@Suite(.timeLimit(.minutes(1)))
struct ScreenshotDeadlineTests {
  @Test
  func completionCancelsDeadline() async throws {
    let timer = TestSuspension()
    let result = try await ScreenshotDeadline.run(sleep: { duration in
      #expect(duration == .seconds(1))
      try await timer.wait()
    }) { 42 }
    #expect(result == 42)
    #expect(timer.wasCancelled)
  }

  @Test
  func timeoutCancelsOperation() async throws {
    let timer = TestSuspension()
    let operation = TestSuspension()
    let task = Task {
      try await ScreenshotDeadline.run(sleep: { duration in
        #expect(duration == .seconds(1))
        try await timer.wait()
      }) {
        try await operation.wait()
      }
    }
    await operation.waitUntilStarted()
    timer.resume()
    do {
      try await task.value
      Issue.record("Expected screenshot timeout")
    } catch ADBError.requestTimedOut(let message) {
      #expect(message == "Screenshot capture timed out after 1 second")
    }
    #expect(operation.wasCancelled)
  }

  @Test
  func cancellationCancelsOperationAndDeadline() async throws {
    let timer = TestSuspension()
    let operation = TestSuspension()
    let task = Task {
      try await ScreenshotDeadline.run(sleep: { _ in try await timer.wait() }) {
        try await operation.wait()
      }
    }
    await operation.waitUntilStarted()
    await timer.waitUntilStarted()
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(operation.wasCancelled)
    #expect(timer.wasCancelled)
  }
}

private final class TestSuspension: @unchecked Sendable {
  private let started = AsyncStream<Void>.makeStream()
  private let resumed = AsyncStream<Void>.makeStream()
  private let lock = NSLock()
  private var cancelled = false

  var wasCancelled: Bool {
    lock.withLock { cancelled }
  }

  func wait() async throws {
    started.continuation.yield(())
    var iterator = resumed.stream.makeAsyncIterator()
    _ = await iterator.next()
    if Task.isCancelled {
      lock.withLock { cancelled = true }
      throw CancellationError()
    }
  }

  func waitUntilStarted() async {
    var iterator = started.stream.makeAsyncIterator()
    _ = await iterator.next()
  }

  func resume() {
    resumed.continuation.yield(())
  }
}
