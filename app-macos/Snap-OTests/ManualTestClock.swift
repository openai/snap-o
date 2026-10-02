import Foundation

/// Advances synchronous socket deadlines without waiting on the system clock.
final class ManualTestClock: Clock, @unchecked Sendable {
  typealias Instant = ContinuousClock.Instant
  typealias Duration = Swift.Duration

  private let lock = NSLock()
  private var instant = ContinuousClock.now
  let minimumResolution: Duration = .nanoseconds(1)

  var now: Instant {
    lock.withLock { instant }
  }

  func advance(by duration: Duration) {
    lock.withLock { instant = instant.advanced(by: duration) }
  }

  func sleep(until _: Instant, tolerance _: Duration?) async throws {
    preconditionFailure("Use TestClock for asynchronous sleeps")
  }
}
