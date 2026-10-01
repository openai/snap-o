import Clocks
import Dependencies
import DependenciesTestSupport
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
  private let changed = TestSignal()

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
      await withCheckedContinuation {
        gate = $0
        changed.signal()
      }
    }
    changed.signal()
    if shouldFail { throw ADBError.protocolFailure("Test send failed") }
  }

  func holdNextSend(failing: Bool) {
    holdFirstSend = true
    failNextSend = failing
  }

  func stop() async {
    isStopped = true
    changed.signal()
  }

  func waitForEvents(_ count: Int) async throws {
    while events.count < count {
      try await changed.wait(after: changed.revision)
    }
  }

  func waitUntilStopped() async throws {
    while !isStopped {
      try await changed.wait(after: changed.revision)
    }
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

@Suite(.timeLimit(.minutes(1)), .dependency(\.continuousClock, TestClock()))
struct LivePreviewPointerTests {
  private static var clock: TestClock<Duration> {
    @Dependency(\.continuousClock, as: TestClock<Duration>.self) var clock
    return clock
  }

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

  private static func injector(_ backend: RecordingBackend) -> LivePreviewPointerInjector {
    LivePreviewPointerInjector(
      makePreferredBackend: { _ in throw CancellationError() }, fallbackBackend: backend
    )
  }

  @Test
  static func multitouchWaitsForPreparation() async throws {
    let preparation = RecordingBackend(holdFirstSend: true)
    let preferred = RecordingBackend(minimumMoveInterval: .zero)
    let sender = LivePreviewPointerInjector(makePreferredBackend: { _ in
      try await preparation.send(event(.down))
      return preferred
    }, fallbackBackend: RecordingBackend(minimumMoveInterval: .zero))
    var down = event(.down)
    down.locations.append(CGPoint(x: 50, y: 50))
    await sender.enqueue(down)
    try await preparation.waitForEvents(1)
    for action in [LivePreviewPointerAction.move, .up] {
      var touch = event(action)
      touch.locations = down.locations
      await sender.enqueue(touch)
    }

    await preparation.release()

    try await preferred.waitForEvents(3)
    let sent = await preferred.events
    #expect(sent.map(\.action) == [.down, .move, .up])
    await sender.stopAll()
  }

  @Test
  static func stoppingDuringPreparationDiscardsPendingMultitouch() async throws {
    let preparation = RecordingBackend(holdFirstSend: true)
    let preferred = RecordingBackend()
    let sender = LivePreviewPointerInjector(makePreferredBackend: { _ in
      try await preparation.send(event(.down))
      return preferred
    }, fallbackBackend: RecordingBackend())
    var down = event(.down)
    down.locations.append(CGPoint(x: 50, y: 50))
    await sender.enqueue(down)
    try await preparation.waitForEvents(1)

    await sender.stopDevice("test-device")
    await preparation.release()

    try await preferred.waitUntilStopped()
    #expect(await preferred.events.isEmpty)
  }

  @Test
  static func shellFallbackDoesNotTurnMultitouchIntoSingleTouch() async throws {
    let backend = RecordingBackend()
    let sender = injector(backend)
    for action in [LivePreviewPointerAction.down, .move, .up] {
      var touch = event(action)
      touch.locations.append(CGPoint(x: 50, y: 50))
      await sender.enqueue(touch)
    }
    await clock.advance(by: .seconds(1))
    await sender.enqueue(event(.down))
    try await backend.waitForEvents(1)
    let sent = await backend.events
    #expect(sent[0].locations.count == 1)
    #expect(sent[0].action == .down)
    await sender.stopAll()
  }

  @Test(arguments: [Duration.nanoseconds(8_333_334), .nanoseconds(16_666_667)])
  static func latestMoveSurvivesSlowSend(interval: Duration) async throws {
    let backend = RecordingBackend(holdFirstSend: true, minimumMoveInterval: interval)
    let sender = injector(backend)
    await sender.enqueue(event(.down))
    try await backend.waitForEvents(1)
    for x in 1 ... 100 {
      await sender.enqueue(event(.move, x: Double(x)))
    }
    await clock.advance(by: .seconds(1))
    await backend.release()
    try await backend.waitForEvents(2)
    let sent = await backend.events
    #expect(sent.map(\.action) == [.down, .move])
    #expect(sent.last?.locations.first?.x == 100)
    await sender.enqueue(event(.move, x: 101))
    await #expect(throws: SuspensionError.self) { try await clock.checkSuspension() }
    await clock.advance(by: interval)
    try await backend.waitForEvents(3)
    await sender.stopAll()
  }

  @Test
  static func pacedMoveUsesLatestPosition() async throws {
    let backend = RecordingBackend()
    let sender = injector(backend)
    await sender.enqueue(event(.down))
    try await backend.waitForEvents(1)
    await sender.enqueue(event(.move, x: 1))
    await #expect(throws: SuspensionError.self) { try await clock.checkSuspension() }
    await sender.enqueue(event(.move, x: 2))
    await clock.advance(by: .milliseconds(17))
    try await backend.waitForEvents(2)
    let sent = await backend.events
    #expect(sent.last?.locations.first?.x == 2)
    // No later input is needed to deliver a move that arrived inside the pacing interval.
    await sender.enqueue(event(.up, x: 3))
    try await backend.waitForEvents(3)
    let lastAction = await backend.events.last?.action
    #expect(lastAction == .up)
    await sender.stopAll()
  }

  @Test
  static func gestureBoundariesStayOrdered() async throws {
    let backend = RecordingBackend(holdFirstSend: true)
    let sender = injector(backend)
    await sender.enqueue(event(.down))
    try await backend.waitForEvents(1)
    for (action, x) in [(LivePreviewPointerAction.move, 1.0), (.up, 2), (.down, 3), (.move, 4), (.cancel, 5)] {
      await sender.enqueue(event(action, x: x))
    }
    await clock.advance(by: .milliseconds(17))
    await backend.release()
    try await backend.waitForEvents(4)
    await #expect(throws: SuspensionError.self) { try await clock.checkSuspension() }
    await clock.advance(by: .milliseconds(17))
    try await backend.waitForEvents(6)
    let sent = await backend.events
    #expect(sent.map(\.action) == [.down, .move, .up, .down, .move, .cancel])
    #expect(sent.map { $0.locations[0].x } == [0, 1, 2, 3, 4, 5])
    await sender.stopAll()
  }

  @Test
  static func stopDiscardsWaitingMove() async throws {
    let backend = RecordingBackend()
    let sender = injector(backend)
    await sender.enqueue(event(.down))
    try await backend.waitForEvents(1)
    await sender.enqueue(event(.move, x: 1))
    await #expect(throws: SuspensionError.self) { try await clock.checkSuspension() }
    await sender.stopDevice("test-device")
    await clock.advance(by: .milliseconds(17))
    await sender.enqueue(event(.move, source: .mouse))
    try await backend.waitForEvents(2)
    let sent = await backend.events
    #expect(sent.last?.source == .mouse)
    await sender.stopAll()
  }

  @Test
  static func hoverIsNotPaced() async throws {
    let backend = RecordingBackend()
    let sender = injector(backend)
    await sender.enqueue(event(.move, source: .mouse))
    try await backend.waitForEvents(1)
    await sender.enqueue(event(.move, x: 2, source: .mouse))
    try await backend.waitForEvents(2)
    try await clock.checkSuspension()
    await sender.stopAll()
  }

  private static func preparePreferredBackend(
    _ sender: LivePreviewPointerInjector, preferred: RecordingBackend, fallback: RecordingBackend
  ) async throws {
    await sender.prepare(deviceID: "test-device")?.value
    #expect(await preferred.events.isEmpty)
    #expect(await fallback.events.isEmpty)
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
    try await preferred.waitForEvents(actions.count)
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
    try await preferred.waitForEvents(1)
    await preferred.holdNextSend(failing: true)
    await sender.enqueue(event(action))
    try await preferred.waitForEvents(2)
    if action == .move {
      await sender.enqueue(event(.move, x: 1))
      await sender.enqueue(event(.up))
    }
    for nextAction in [LivePreviewPointerAction.down, .move, .up] {
      await sender.enqueue(event(nextAction))
    }
    await preferred.release()
    try await fallback.waitForEvents(3)
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
    try await old.waitForEvents(1)
    await old.holdNextSend(failing: failing)
    await sender.enqueue(event(action))
    try await old.waitForEvents(2)
    await sender.enqueue(event(.move, x: 99))
    await sender.enqueue(event(.up))
    await sender.stopDevice("test-device")
    await old.release()
    try await preparePreferredBackend(sender, preferred: replacement, fallback: fallback)
    for nextAction in [LivePreviewPointerAction.down, .move, .up] {
      await sender.enqueue(event(nextAction))
    }
    try await replacement.waitForEvents(3)
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
