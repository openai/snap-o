import Foundation
import Observation

/// Waits for observable state changes without depending on scheduler speed.
@MainActor
func waitForState(_ condition: () -> Bool) async throws {
  while true {
    let (changes, continuation) = AsyncStream<Void>.makeStream()
    let satisfied = withObservationTracking {
      condition()
    } onChange: {
      continuation.yield(())
    }
    if satisfied {
      continuation.finish()
      return
    }
    var iterator = changes.makeAsyncIterator()
    _ = await iterator.next()
    continuation.finish()
    try Task.checkCancellation()
  }
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
func suspendUntilCancelled(_: Duration) async throws {
  let (stream, continuation) = AsyncStream<Void>.makeStream()
  defer { continuation.finish() }
  for await _ in stream {}
  try Task.checkCancellation()
}
