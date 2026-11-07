import Foundation
import Observation

/// Waits for observable state changes without depending on scheduler speed.
@MainActor
func waitForState(_ condition: @escaping @MainActor @Sendable () -> Bool) async throws {
  let states = Observations { condition() }
  for await satisfied in states where satisfied {
    return
  }
  try Task.checkCancellation()
}

@Observable
@MainActor
final class TestValue<Value> {
  var value: Value

  init(_ value: Value) {
    self.value = value
  }
}

/// Holds background polling until the owner cancels it.
func suspendUntilCancelled() async throws {
  let (stream, continuation) = AsyncStream<Void>.makeStream()
  defer { continuation.finish() }
  for await _ in stream {}
  try Task.checkCancellation()
}

/// Broadcasts changes without losing signals that arrive before a waiter suspends.
final class TestSignal: @unchecked Sendable {
  private let lock = NSLock()
  private var generation: UInt64 = 0
  private var waiters: [UUID: AsyncStream<Void>.Continuation] = [:]

  var revision: UInt64 {
    lock.withLock { generation }
  }

  func signal() {
    let pending = lock.withLock {
      generation &+= 1
      let pending = Array(waiters.values)
      waiters.removeAll()
      return pending
    }
    for waiter in pending {
      waiter.yield(())
    }
  }

  func wait(after revision: UInt64) async throws {
    let id = UUID()
    let (stream, continuation) = AsyncStream<Void>.makeStream()
    lock.withLock {
      if generation != revision {
        continuation.yield(())
      } else {
        waiters[id] = continuation
      }
    }
    defer {
      _ = lock.withLock { waiters.removeValue(forKey: id) }
      continuation.finish()
    }
    var iterator = stream.makeAsyncIterator()
    _ = await iterator.next()
    try Task.checkCancellation()
  }
}

final class TestSuspension: @unchecked Sendable {
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
