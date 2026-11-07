import Dependencies
import Foundation

/// Responses and stream heartbeats postpone redundant background probes.
final class ToolConnectionHealth: @unchecked Sendable {
  private let clock: AnyClock<Duration>
  private let lock = NSLock()
  private var lastActivity: AnyClock<Duration>.Instant?
  private var activityRevision: UInt64 = 0

  init(clock: AnyClock<Duration>) {
    self.clock = clock
  }

  var revision: UInt64 {
    lock.withLock { activityRevision }
  }

  var needsProbe: Bool {
    lock.withLock {
      guard let lastActivity else { return true }
      // The shared tool server sends idle SSE heartbeats every 30 seconds.
      return lastActivity.duration(to: clock.now) >= .seconds(45)
    }
  }

  func recordActivity() {
    lock.withLock {
      lastActivity = clock.now
      activityRevision &+= 1
    }
  }

  func requestFailed(since revision: UInt64) {
    lock.withLock {
      guard activityRevision == revision else { return }
      lastActivity = nil
    }
  }
}
