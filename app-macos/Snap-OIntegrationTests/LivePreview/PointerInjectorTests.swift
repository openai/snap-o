import Clocks
import Dependencies
import DependenciesTestSupport
import Foundation
#if canImport(Snap_O) && !SNAPO_STANDALONE_TESTS
@testable import Snap_O
#endif
import Testing

private actor RecordingBackend: LivePreviewPointerBackend {
  let minimumMoveInterval: Duration
  private(set) var events: [LivePreviewPointerEvent] = []
  private(set) var isStopped = false
  private var gate: CheckedContinuation<Void, Never>?
  private var holdFirstSend: Bool
  private var failNextSend = false
  private var wasCancelled = false
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
      await withTaskCancellationHandler {
        await withCheckedContinuation {
          gate = $0
          changed.signal()
        }
      } onCancel: { Task { await self.recordCancellation() } }
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

  private func recordCancellation() {
    wasCancelled = true
    changed.signal()
  }

  func waitForCancellation() async throws {
    while !wasCancelled {
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

private actor StopCompletions {
  private(set) var count = 0
  func record() {
    count += 1
  }
}

@Suite(.timeLimit(.minutes(1)), .dependency(\.continuousClock, TestClock()))
struct LivePreviewPointerTests {
  private let target = DeviceTarget(serial: "test-device", transportID: "1")

  private var clock: TestClock<Duration> {
    @Dependency(\.continuousClock, as: TestClock<Duration>.self) var clock
    return clock
  }

  private func event(
    _ action: LivePreviewPointerAction, x: Double = 0,
    for target: DeviceTarget? = nil,
    source: LivePreviewPointerSource = .touchscreen,
    size: CGSize = CGSize(width: 100, height: 200)
  ) -> LivePreviewPointerEvent {
    LivePreviewPointerEvent(
      target: target ?? self.target,
      action: action,
      source: source,
      locations: [CGPoint(x: x, y: 10)],
      displaySize: size
    )
  }

  private func injector(_ backend: RecordingBackend) -> LivePreviewPointerInjector {
    LivePreviewPointerInjector(
      makePreferredBackend: { _ in throw CancellationError() }, makeFallbackBackend: { _ in backend }
    )
  }

  @Test(arguments: [false, true])
  func focusReleaseJoinsDownAndKeepsTheBackend(preferred: Bool) async throws {
    let backend = RecordingBackend(holdFirstSend: true, minimumMoveInterval: .zero)
    let fallback = preferred ? RecordingBackend() : backend
    let sender = LivePreviewPointerInjector(
      makePreferredBackend: { _ in
        if preferred { return backend }
        throw CancellationError()
      },
      makeFallbackBackend: { _ in fallback }
    )
    await sender.prepare(target: target)?.value
    await sender.enqueue(event(.down))
    try await backend.waitForEvents(1)
    await sender.enqueue(event(.move, x: 99))
    let release = Task { await sender.releaseInput(for: target) }
    try await backend.waitForCancellation()
    await sender.enqueue(event(.down, x: 50))
    await backend.release()
    await release.value
    #expect(await backend.events.map(\.action) == [.down, .cancel])
    #expect(await !backend.isStopped)
    await sender.enqueue(event(.down, x: 2))
    await sender.enqueue(event(.up, x: 2))
    try await backend.waitForEvents(4)
    #expect(await backend.events.map(\.action) == [.down, .cancel, .down, .up])
    await sender.stopAll()
  }

  @Test
  func focusReleaseCancelsMouseButtonsWithoutClosingTheBackend() async throws {
    let backend = RecordingBackend(holdFirstSend: true)
    let sender = injector(backend)
    await sender.enqueue(event(.down, source: .mouse))
    try await backend.waitForEvents(1)
    let release = Task { await sender.releaseInput(for: target) }
    try await backend.waitForCancellation()
    await backend.release()
    await release.value
    #expect(await backend.events.map(\.action) == [.down, .cancel])
    #expect(await !backend.isStopped)
    await sender.stopAll()
  }

  @Test
  func replacementKeepsItsOwnBackendAfterOldPreparationFinishes() async throws {
    let replacement = DeviceTarget(serial: target.serial, transportID: "2")
    let preparation = RecordingBackend(holdFirstSend: true)
    let oldBackend = RecordingBackend(minimumMoveInterval: .zero)
    let newBackend = RecordingBackend(minimumMoveInterval: .zero)
    let sender = LivePreviewPointerInjector(makePreferredBackend: { connection in
      if connection == target {
        try await preparation.send(event(.down))
        return oldBackend
      }
      return newBackend
    }, makeFallbackBackend: { _ in RecordingBackend(minimumMoveInterval: .zero) })
    let oldPreparation = await sender.prepare(target: target)
    try await preparation.waitForEvents(1)
    target.invalidate()
    await sender.prepare(target: replacement)?.value
    await sender.enqueue(event(.down, for: replacement))
    try await newBackend.waitForEvents(1)
    await preparation.release()
    await oldPreparation?.value
    try await oldBackend.waitUntilStopped()
    await sender.enqueue(event(.move, for: replacement))
    await sender.enqueue(event(.up, for: replacement))
    try await newBackend.waitForEvents(3)
    #expect(await oldBackend.events.isEmpty)
    #expect(await newBackend.events.map(\.action) == [.down, .move, .up])
    #expect(await newBackend.isStopped == false)
    await sender.stopAll()
  }

  @Test
  func slowDeviceDoesNotBlockAnotherDevicesInput() async throws {
    let backend = RecordingBackend(holdFirstSend: true, minimumMoveInterval: .zero)
    let sender = injector(backend)
    let second = DeviceTarget(serial: "second-device", transportID: "2")
    await sender.enqueue(event(.down))
    try await backend.waitForEvents(1)
    await sender.enqueue(event(.down, for: second))
    try await backend.waitForEvents(2)
    #expect(await backend.events.map(\.target) == [target, second])
    await backend.release()
    await sender.stopAll()
  }

  @Test(arguments: [false, true])
  func stoppingJoinsLatePreparationForAllCallers(shutsDown: Bool) async throws {
    let preparation = RecordingBackend(holdFirstSend: true)
    let preferred = RecordingBackend()
    let sender = LivePreviewPointerInjector(makePreferredBackend: { _ in
      try await preparation.send(event(.down))
      return preferred
    }, makeFallbackBackend: { _ in RecordingBackend() })
    await sender.prepare(target: target)
    try await preparation.waitForEvents(1)
    let finished = StopCompletions()
    let first = Task { await sender.stopDevice(target)
      await finished.record()
    }
    try await preparation.waitForCancellation()
    let second = Task {
      if shutsDown { await sender.stopAll() } else { await sender.stopDevice(target) }
      await finished.record()
    }
    #expect(await finished.count == 0, "Stop must wait for cancellation-insensitive preparation")
    await preparation.release()
    await first.value
    await second.value
    #expect(await preferred.isStopped)
    #expect(await finished.count == 2)
  }

  @Test
  func shutdownJoinsSendsAndRejectsNewInput() async throws {
    let backend = RecordingBackend(holdFirstSend: true)
    let sender = injector(backend)
    await sender.enqueue(event(.down))
    try await backend.waitForEvents(1)
    let finished = StopCompletions()
    let stop = Task { await sender.stopAll()
      await finished.record()
    }
    try await backend.waitForCancellation()
    #expect(await finished.count == 0)
    await sender.enqueue(event(.down, source: .mouse))
    await backend.release()
    await stop.value
    await sender.enqueue(event(.down))
    #expect(await backend.events.count == 1)
    #expect(await backend.isStopped)
    #expect(await finished.count == 1)
    try await clock.checkSuspension()
  }

  @Test
  func multitouchWaitsForPreparation() async throws {
    let preparation = RecordingBackend(holdFirstSend: true)
    let preferred = RecordingBackend(minimumMoveInterval: .zero)
    let sender = LivePreviewPointerInjector(makePreferredBackend: { _ in
      try await preparation.send(event(.down))
      return preferred
    }, makeFallbackBackend: { _ in RecordingBackend(minimumMoveInterval: .zero) })
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
  func stoppingDuringPreparationDiscardsPendingMultitouch() async throws {
    let preparation = RecordingBackend(holdFirstSend: true)
    let preferred = RecordingBackend()
    let sender = LivePreviewPointerInjector(makePreferredBackend: { _ in
      try await preparation.send(event(.down))
      return preferred
    }, makeFallbackBackend: { _ in RecordingBackend() })
    var down = event(.down)
    down.locations.append(CGPoint(x: 50, y: 50))
    await sender.enqueue(down)
    try await preparation.waitForEvents(1)

    let stopping = Task { await sender.stopDevice(target) }
    try await preparation.waitForCancellation()
    await preparation.release()
    await stopping.value

    try await preferred.waitUntilStopped()
    #expect(await preferred.events.isEmpty)
  }

  @Test
  func fallbackPreservesMultitouchContacts() async throws {
    let backend = RecordingBackend(minimumMoveInterval: .zero)
    let sender = injector(backend)
    for action in [LivePreviewPointerAction.down, .move, .up] {
      var touch = event(action)
      touch.locations.append(CGPoint(x: 50, y: 50))
      await sender.enqueue(touch)
    }
    try await backend.waitForEvents(3)
    let sent = await backend.events
    #expect(sent.map(\.action) == [.down, .move, .up])
    #expect(sent.allSatisfy { $0.locations.count == 2 })
    await sender.stopAll()
  }

  @Test(arguments: [Duration.nanoseconds(8_333_334), .nanoseconds(16_666_667)])
  func latestMoveSurvivesSlowSend(interval: Duration) async throws {
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
    await clock.advance(by: interval)
    try await backend.waitForEvents(3)
    await sender.stopAll()
  }

  @Test
  func pacedMoveUsesLatestPosition() async throws {
    let backend = RecordingBackend()
    let sender = injector(backend)
    await sender.enqueue(event(.down))
    try await backend.waitForEvents(1)
    await sender.enqueue(event(.move, x: 1))
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
  func gestureBoundariesStayOrdered() async throws {
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
    await clock.advance(by: .milliseconds(17))
    try await backend.waitForEvents(6)
    let sent = await backend.events
    #expect(sent.map(\.action) == [.down, .move, .up, .down, .move, .cancel])
    #expect(sent.map { $0.locations[0].x } == [0, 1, 2, 3, 4, 5])
    await sender.stopAll()
  }

  @Test
  func stopDiscardsWaitingMove() async throws {
    let backend = RecordingBackend()
    let sender = injector(backend)
    await sender.enqueue(event(.down))
    try await backend.waitForEvents(1)
    await sender.enqueue(event(.move, x: 1))
    await sender.stopDevice(target)
    await clock.advance(by: .milliseconds(17))
    await sender.enqueue(event(.move, source: .mouse))
    try await backend.waitForEvents(2)
    let sent = await backend.events
    #expect(sent.last?.source == .mouse)
    await sender.stopAll()
  }

  @Test
  func hoverIsNotPaced() async throws {
    let backend = RecordingBackend()
    let sender = injector(backend)
    await sender.enqueue(event(.move, source: .mouse))
    try await backend.waitForEvents(1)
    await sender.enqueue(event(.move, x: 2, source: .mouse))
    try await backend.waitForEvents(2)
    try await clock.checkSuspension()
    await sender.stopAll()
  }

  private func preparePreferredBackend(
    _ sender: LivePreviewPointerInjector, preferred: RecordingBackend, fallback: RecordingBackend
  ) async throws {
    await sender.prepare(target: target)?.value
    #expect(await preferred.events.isEmpty)
    #expect(await fallback.events.isEmpty)
  }

  @Test(arguments: [LivePreviewPointerAction.up, .cancel])
  func preferredGestureEnds(_ endAction: LivePreviewPointerAction) async throws {
    let preferred = RecordingBackend(minimumMoveInterval: .zero)
    let fallback = RecordingBackend(minimumMoveInterval: .zero)
    let sender = LivePreviewPointerInjector(makePreferredBackend: { _ in preferred }, makeFallbackBackend: { _ in fallback })
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
  func preferredFailureWaitsForNextGesture(_ action: LivePreviewPointerAction) async throws {
    let preferred = RecordingBackend(minimumMoveInterval: .zero)
    let fallback = RecordingBackend(minimumMoveInterval: .zero)
    let sender = LivePreviewPointerInjector(makePreferredBackend: { _ in preferred }, makeFallbackBackend: { _ in fallback })
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
  func reconnectIgnoresOldSend(_ action: LivePreviewPointerAction, failing: Bool) async throws {
    let old = RecordingBackend(minimumMoveInterval: .zero)
    let replacement = RecordingBackend(minimumMoveInterval: .zero)
    let fallback = RecordingBackend(minimumMoveInterval: .zero)
    let backends = BackendSequence([old, replacement])
    let sender = LivePreviewPointerInjector(makePreferredBackend: { _ in await backends.next() }, makeFallbackBackend: { _ in fallback })
    try await preparePreferredBackend(sender, preferred: old, fallback: fallback)
    await sender.enqueue(event(.down))
    try await old.waitForEvents(1)
    await old.holdNextSend(failing: failing)
    await sender.enqueue(event(action))
    try await old.waitForEvents(2)
    await sender.enqueue(event(.move, x: 99))
    await sender.enqueue(event(.up))
    let stopping = Task { await sender.stopDevice(target) }
    try await old.waitUntilStopped()
    await old.release()
    await stopping.value
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
