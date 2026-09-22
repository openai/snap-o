import Foundation
@testable import Snap_O
import Testing

private actor RecordingBackend: LivePreviewPointerBackend {
  let minimumMoveInterval: Duration
  private(set) var events: [LivePreviewPointerEvent] = []
  private(set) var isStopped = false
  private var gate: CheckedContinuation<Void, Never>?
  private var holdFirstSend: Bool
  private var failNextSend = false

  init(holdFirstSend: Bool = false, minimumMoveInterval: Duration = .nanoseconds(16_666_667)) {
    self.holdFirstSend = holdFirstSend
    self.minimumMoveInterval = minimumMoveInterval
  }

  func send(_ event: LivePreviewPointerEvent) async throws {
    let shouldFail = failNextSend
    failNextSend = false
    events.append(event)
    if holdFirstSend {
      holdFirstSend = false
      await withCheckedContinuation { gate = $0 }
    }
    if shouldFail { throw ADBError.protocolFailure("Test send failed") }
  }

  func holdNextSend(failing: Bool) {
    holdFirstSend = true
    failNextSend = failing
  }

  func resetEvents() {
    events.removeAll()
  }

  func stop() async {
    isStopped = true
  }

  func release() {
    gate?.resume()
    gate = nil
  }
}

private actor BackendSequence {
  private var backends: [RecordingBackend]

  init(_ backends: [RecordingBackend]) {
    self.backends = backends
  }

  func next() -> RecordingBackend {
    backends.removeFirst()
  }
}

private final class TestClock: @unchecked Sendable {
  private let lock = NSLock()
  private var instant = ContinuousClock.now
  private var waiters: [(ContinuousClock.Instant, CheckedContinuation<Void, Never>)] = []

  var now: ContinuousClock.Instant {
    lock.withLock { instant }
  }

  var isSleeping: Bool {
    lock.withLock { !waiters.isEmpty }
  }

  func sleep(until deadline: ContinuousClock.Instant) async {
    await withCheckedContinuation { continuation in
      lock.withLock {
        if instant >= deadline {
          continuation.resume()
        } else {
          waiters.append((deadline, continuation))
        }
      }
    }
  }

  func advance(by duration: Duration = .milliseconds(17)) {
    lock.withLock {
      instant = instant.advanced(by: duration)
      let ready = waiters.filter { $0.0 <= instant }
      waiters.removeAll { $0.0 <= instant }
      for (_, continuation) in ready {
        continuation.resume()
      }
    }
  }
}

struct LivePreviewPointerTests {
  private static func event(
    _ action: LivePreviewPointerAction, x: Double = 0,
    source: LivePreviewPointerSource = .touchscreen,
    size: CGSize = CGSize(width: 100, height: 200)
  ) -> LivePreviewPointerEvent {
    LivePreviewPointerEvent(
      deviceID: "test-device",
      action: action,
      source: source,
      locations: [CGPoint(x: x, y: 10)],
      displaySize: size
    )
  }

  private static func injector(_ backend: RecordingBackend, clock: TestClock) -> LivePreviewPointerInjector {
    LivePreviewPointerInjector(
      makePreferredBackend: { _ in throw CancellationError() }, fallbackBackend: backend,
      now: { clock.now }, sleepUntil: { await clock.sleep(until: $0) }
    )
  }

  private static func waitUntil(_ condition: () async -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while await !condition() {
      try #require(ContinuousClock.now < deadline, "Timed out waiting for test state")
      try? await Task.sleep(for: .milliseconds(1))
    }
  }

  @Test
  static func shellFallbackDoesNotTurnMultitouchIntoSingleTouch() async throws {
    let backend = RecordingBackend()
    let clock = TestClock()
    let sender = injector(backend, clock: clock)
    for action in [LivePreviewPointerAction.down, .move, .up] {
      var touch = event(action)
      touch.locations.append(CGPoint(x: 50, y: 50))
      await sender.enqueue(touch)
    }
    clock.advance(by: .seconds(1))
    await sender.enqueue(event(.down))
    try await waitUntil { await backend.events.count == 1 }
    let sent = await backend.events
    #expect(sent[0].locations.count == 1)
    #expect(sent[0].action == .down)
    await sender.stopAll()
  }

  @Test(arguments: [Duration.nanoseconds(8_333_334), .nanoseconds(16_666_667)])
  static func latestMoveSurvivesSlowSend(interval: Duration) async throws {
    let clock = TestClock()
    let backend = RecordingBackend(holdFirstSend: true, minimumMoveInterval: interval)
    let sender = injector(backend, clock: clock)
    await sender.enqueue(event(.down))
    try await waitUntil { await backend.events.count == 1 }
    for x in 1 ... 100 {
      await sender.enqueue(event(.move, x: Double(x)))
    }
    clock.advance(by: .seconds(1))
    await backend.release()
    try await waitUntil { await backend.events.count == 2 }
    let sent = await backend.events
    #expect(sent.map(\.action) == [.down, .move])
    #expect(sent.last?.locations.first?.x == 100)
    await sender.enqueue(event(.move, x: 101))
    try await waitUntil { clock.isSleeping }
    clock.advance(by: interval)
    try await waitUntil { await backend.events.count == 3 }
    await sender.stopAll()
  }

  @Test
  static func pacedMoveUsesLatestPosition() async throws {
    let clock = TestClock()
    let backend = RecordingBackend()
    let sender = injector(backend, clock: clock)
    await sender.enqueue(event(.down))
    try await waitUntil { await backend.events.count == 1 }
    await sender.enqueue(event(.move, x: 1))
    try await waitUntil { clock.isSleeping }
    await sender.enqueue(event(.move, x: 2))
    clock.advance()
    try await waitUntil { await backend.events.count == 2 }
    let sent = await backend.events
    #expect(sent.last?.locations.first?.x == 2)
    // No later input is needed to deliver a move that arrived inside the pacing interval.
    await sender.enqueue(event(.up, x: 3))
    try await waitUntil { await backend.events.count == 3 }
    let lastAction = await backend.events.last?.action
    #expect(lastAction == .up)
    await sender.stopAll()
  }

  @Test
  static func gestureBoundariesStayOrdered() async throws {
    let clock = TestClock()
    let backend = RecordingBackend(holdFirstSend: true)
    let sender = injector(backend, clock: clock)
    await sender.enqueue(event(.down))
    try await waitUntil { await backend.events.count == 1 }
    for (action, x) in [(LivePreviewPointerAction.move, 1.0), (.up, 2), (.down, 3), (.move, 4), (.cancel, 5)] {
      await sender.enqueue(event(action, x: x))
    }
    clock.advance()
    await backend.release()
    try await waitUntil { await backend.events.count == 4 }
    try await waitUntil { clock.isSleeping }
    clock.advance()
    try await waitUntil { await backend.events.count == 6 }
    let sent = await backend.events
    #expect(sent.map(\.action) == [.down, .move, .up, .down, .move, .cancel])
    #expect(sent.map { $0.locations[0].x } == [0, 1, 2, 3, 4, 5])
    await sender.stopAll()
  }

  @Test
  static func stopDiscardsWaitingMove() async throws {
    let clock = TestClock()
    let backend = RecordingBackend()
    let sender = injector(backend, clock: clock)
    await sender.enqueue(event(.down))
    try await waitUntil { await backend.events.count == 1 }
    await sender.enqueue(event(.move, x: 1))
    try await waitUntil { clock.isSleeping }
    await sender.stopDevice("test-device")
    clock.advance()
    await sender.enqueue(event(.move, source: .mouse))
    try await waitUntil { await backend.events.count == 2 }
    let sent = await backend.events
    #expect(sent.last?.source == .mouse)
    await sender.stopAll()
  }

  @Test
  static func hoverIsNotPaced() async throws {
    let clock = TestClock()
    let backend = RecordingBackend()
    let sender = injector(backend, clock: clock)
    await sender.enqueue(event(.move, source: .mouse))
    try await waitUntil { await backend.events.count == 1 }
    await sender.enqueue(event(.move, x: 2, source: .mouse))
    try await waitUntil { await backend.events.count == 2 }
    #expect(!clock.isSleeping)
    await sender.stopAll()
  }

  private static func preparePreferredBackend(
    _ sender: LivePreviewPointerInjector, preferred: RecordingBackend, fallback: RecordingBackend
  ) async throws {
    await sender.prepare(deviceID: "test-device")
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    // Preparation is asynchronous; complete taps until the preferred backend accepts one.
    while await preferred.events.isEmpty {
      try #require(ContinuousClock.now < deadline, "Preferred backend never became ready")
      let fallbackCount = await fallback.events.count
      await sender.enqueue(event(.down))
      await sender.enqueue(event(.up))
      try await waitUntil {
        let preferredCount = await preferred.events.count
        let count = await fallback.events.count
        return preferredCount == 2 || count == fallbackCount + 2
      }
    }
    await preferred.resetEvents()
    await fallback.resetEvents()
  }

  @Test(arguments: [LivePreviewPointerAction.up, .cancel])
  static func preferredGestureEnds(_ endAction: LivePreviewPointerAction) async throws {
    let preferred = RecordingBackend(minimumMoveInterval: .zero)
    let fallback = RecordingBackend(minimumMoveInterval: .zero)
    let sender = LivePreviewPointerInjector(makePreferredBackend: { _ in preferred }, fallbackBackend: fallback)
    try await preparePreferredBackend(sender, preferred: preferred, fallback: fallback)
    let actions: [LivePreviewPointerAction] = [.down, .move, endAction, .down, .up]
    for action in actions {
      await sender.enqueue(event(action))
    }
    try await waitUntil { await preferred.events.count == actions.count }
    let sent = await preferred.events
    let fallbackEvents = await fallback.events
    #expect(sent.map(\.action) == actions && fallbackEvents.isEmpty)
    await sender.stopAll()
  }

  @Test(arguments: [LivePreviewPointerAction.move, .up, .cancel])
  static func preferredFailureWaitsForNextGesture(_ action: LivePreviewPointerAction) async throws {
    let preferred = RecordingBackend(minimumMoveInterval: .zero)
    let fallback = RecordingBackend(minimumMoveInterval: .zero)
    let sender = LivePreviewPointerInjector(makePreferredBackend: { _ in preferred }, fallbackBackend: fallback)
    try await preparePreferredBackend(sender, preferred: preferred, fallback: fallback)
    await sender.enqueue(event(.down))
    try await waitUntil { await preferred.events.count == 1 }
    await preferred.holdNextSend(failing: true)
    await sender.enqueue(event(action))
    try await waitUntil { await preferred.events.count == 2 }
    if action == .move {
      await sender.enqueue(event(.move, x: 1))
      await sender.enqueue(event(.up))
    }
    for nextAction in [LivePreviewPointerAction.down, .move, .up] {
      await sender.enqueue(event(nextAction))
    }
    await preferred.release()
    try await waitUntil { await fallback.events.count == 3 }
    let preferredEvents = await preferred.events
    let fallbackEvents = await fallback.events
    let stopped = await preferred.isStopped
    #expect(preferredEvents.map(\.action) == [.down, action] && stopped)
    #expect(fallbackEvents.map(\.action) == [.down, .move, .up])
    await sender.stopAll()
  }

  @Test(arguments: [LivePreviewPointerAction.move, .up, .cancel], [false, true])
  static func reconnectIgnoresOldSend(_ action: LivePreviewPointerAction, failing: Bool) async throws {
    let old = RecordingBackend(minimumMoveInterval: .zero)
    let replacement = RecordingBackend(minimumMoveInterval: .zero)
    let fallback = RecordingBackend(minimumMoveInterval: .zero)
    let backends = BackendSequence([old, replacement])
    let sender = LivePreviewPointerInjector(makePreferredBackend: { _ in await backends.next() }, fallbackBackend: fallback)
    try await preparePreferredBackend(sender, preferred: old, fallback: fallback)
    await sender.enqueue(event(.down))
    try await waitUntil { await old.events.count == 1 }
    await old.holdNextSend(failing: failing)
    await sender.enqueue(event(action))
    try await waitUntil { await old.events.count == 2 }
    await sender.enqueue(event(.move, x: 99))
    await sender.enqueue(event(.up))
    await sender.stopDevice("test-device")
    await sender.prepare(deviceID: "test-device")
    await old.release()
    try await preparePreferredBackend(sender, preferred: replacement, fallback: fallback)
    for nextAction in [LivePreviewPointerAction.down, .move, .up] {
      await sender.enqueue(event(nextAction))
    }
    try await waitUntil { await replacement.events.count == 3 }
    let oldEvents = await old.events
    let replacementEvents = await replacement.events
    let fallbackEvents = await fallback.events
    let stopped = await replacement.isStopped
    #expect(oldEvents.map(\.action) == [.down, action])
    #expect(replacementEvents.map(\.action) == [.down, .move, .up])
    #expect(fallbackEvents.isEmpty && !stopped)
    await sender.stopAll()
  }
}
