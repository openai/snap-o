import Foundation
import SnapODeviceClient

actor ADBService {
  let client: ADBClient
  init(client: ADBClient) {
    self.client = client
  }

  func exec() -> ADBClient {
    client
  }
}

struct ShellLivePreviewPointerBackend: LivePreviewPointerBackend {
  init(adb: ADBService) {}
  func send(_ event: LivePreviewPointerEvent) async throws {}
}

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

@main
struct LivePreviewPointerTests {
  static func main() async throws {
    await latestMoveSurvivesSlowSend()
    await pacedMoveUsesLatestPosition()
    await fasterBackendKeepsMovesBounded()
    await gestureBoundariesStayOrdered()
    await stopDiscardsWaitingMove()
    await hoverIsNotPaced()
    for endAction in [LivePreviewPointerAction.up, .cancel] {
      await preferredGestureEnds(endAction)
    }
    for action in [LivePreviewPointerAction.move, .up, .cancel] {
      await preferredFailureWaitsForNextGesture(action)
      for failing in [false, true] {
        await reconnectIgnoresOldSend(action, failing: failing)
      }
    }
    try await freshRotationDoesNotQueryOnDown()
    try await activeDragPausesRefreshAndNextDragChecksStaleRotation()
    try await changedSizeRefreshesBeforeDown()
    try await idleRefreshFindsHalfTurn()
    try await stopDuringRefreshDoesNotSend()
    try await failedRefreshDoesNotReuseOldRotation()
    print("Live preview pointer tests passed (23 cases)")
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
      location: CGPoint(x: x, y: 10),
      displaySize: size
    )
  }

  private static func injector(_ backend: RecordingBackend, clock: TestClock) -> LivePreviewPointerInjector {
    LivePreviewPointerInjector(
      makePreferredBackend: { _ in throw CancellationError() }, fallbackBackend: backend,
      now: { clock.now }, sleepUntil: { await clock.sleep(until: $0) }
    )
  }

  private static func waitUntil(_ condition: () async -> Bool) async {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while await !condition() {
      precondition(ContinuousClock.now < deadline, "Timed out waiting for test state")
      try? await Task.sleep(for: .milliseconds(1))
    }
  }

  private static func latestMoveSurvivesSlowSend() async {
    let clock = TestClock()
    let backend = RecordingBackend(holdFirstSend: true)
    let sender = injector(backend, clock: clock)
    await sender.enqueue(event(.down))
    await waitUntil { await backend.events.count == 1 }
    for x in 1 ... 100 {
      await sender.enqueue(event(.move, x: Double(x)))
    }
    clock.advance(by: .seconds(1))
    await backend.release()
    await waitUntil { await backend.events.count == 2 }
    let sent = await backend.events
    precondition(sent.map(\.action) == [.down, .move])
    precondition(sent.last?.location.x == 100)
    await sender.stopAll()
  }

  private static func pacedMoveUsesLatestPosition() async {
    let clock = TestClock()
    let backend = RecordingBackend()
    let sender = injector(backend, clock: clock)
    await sender.enqueue(event(.down))
    await waitUntil { await backend.events.count == 1 }
    await sender.enqueue(event(.move, x: 1))
    await waitUntil { clock.isSleeping }
    await sender.enqueue(event(.move, x: 2))
    clock.advance()
    await waitUntil { await backend.events.count == 2 }
    let sent = await backend.events
    precondition(sent.last?.location.x == 2)
    // No later input is needed to deliver a move that arrived inside the pacing interval.
    await sender.enqueue(event(.up, x: 3))
    await waitUntil { await backend.events.count == 3 }
    let lastAction = await backend.events.last?.action
    precondition(lastAction == .up)
    await sender.stopAll()
  }

  private static func gestureBoundariesStayOrdered() async {
    let clock = TestClock()
    let backend = RecordingBackend(holdFirstSend: true)
    let sender = injector(backend, clock: clock)
    await sender.enqueue(event(.down))
    await waitUntil { await backend.events.count == 1 }
    for (action, x) in [(LivePreviewPointerAction.move, 1.0), (.up, 2), (.down, 3), (.move, 4), (.cancel, 5)] {
      await sender.enqueue(event(action, x: x))
    }
    clock.advance()
    await backend.release()
    await waitUntil { await backend.events.count == 4 }
    await waitUntil { clock.isSleeping }
    clock.advance()
    await waitUntil { await backend.events.count == 6 }
    let sent = await backend.events
    precondition(sent.map(\.action) == [.down, .move, .up, .down, .move, .cancel])
    precondition(sent.map(\.location.x) == [0, 1, 2, 3, 4, 5])
    await sender.stopAll()
  }

  private static func fasterBackendKeepsMovesBounded() async {
    let clock = TestClock()
    let backend = RecordingBackend(holdFirstSend: true, minimumMoveInterval: .nanoseconds(8_333_334))
    let sender = injector(backend, clock: clock)
    await sender.enqueue(event(.down))
    await waitUntil { await backend.events.count == 1 }
    for x in 1 ... 100 {
      await sender.enqueue(event(.move, x: Double(x)))
    }
    clock.advance(by: .milliseconds(9))
    await backend.release()
    await waitUntil { await backend.events.count == 2 }
    let sent = await backend.events
    precondition(sent.last?.location.x == 100)
    await sender.enqueue(event(.move, x: 101))
    await waitUntil { clock.isSleeping }
    clock.advance(by: .milliseconds(9))
    await waitUntil { await backend.events.count == 3 }
    await sender.stopAll()
  }

  private static func stopDiscardsWaitingMove() async {
    let clock = TestClock()
    let backend = RecordingBackend()
    let sender = injector(backend, clock: clock)
    await sender.enqueue(event(.down))
    await waitUntil { await backend.events.count == 1 }
    await sender.enqueue(event(.move, x: 1))
    await waitUntil { clock.isSleeping }
    await sender.stopDevice("test-device")
    clock.advance()
    await sender.enqueue(event(.move, source: .mouse))
    await waitUntil { await backend.events.count == 2 }
    let sent = await backend.events
    precondition(sent.last?.source == .mouse)
    await sender.stopAll()
  }

  private static func hoverIsNotPaced() async {
    let clock = TestClock()
    let backend = RecordingBackend()
    let sender = injector(backend, clock: clock)
    await sender.enqueue(event(.move, source: .mouse))
    await waitUntil { await backend.events.count == 1 }
    await sender.enqueue(event(.move, x: 2, source: .mouse))
    await waitUntil { await backend.events.count == 2 }
    precondition(!clock.isSleeping)
    await sender.stopAll()
  }

  private static func preparePreferredBackend(
    _ sender: LivePreviewPointerInjector, preferred: RecordingBackend, fallback: RecordingBackend
  ) async {
    await sender.prepare(deviceID: "test-device")
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    // Preparation is asynchronous; complete taps until the preferred backend accepts one.
    while await preferred.events.isEmpty {
      precondition(ContinuousClock.now < deadline, "Preferred backend never became ready")
      let fallbackCount = await fallback.events.count
      await sender.enqueue(event(.down))
      await sender.enqueue(event(.up))
      await waitUntil {
        let preferredCount = await preferred.events.count
        let count = await fallback.events.count
        return preferredCount == 2 || count == fallbackCount + 2
      }
    }
    await preferred.resetEvents()
    await fallback.resetEvents()
  }

  private static func preferredGestureEnds(_ endAction: LivePreviewPointerAction) async {
    let preferred = RecordingBackend(minimumMoveInterval: .zero)
    let fallback = RecordingBackend(minimumMoveInterval: .zero)
    let sender = LivePreviewPointerInjector(makePreferredBackend: { _ in preferred }, fallbackBackend: fallback)
    await preparePreferredBackend(sender, preferred: preferred, fallback: fallback)
    let actions: [LivePreviewPointerAction] = [.down, .move, endAction, .down, .up]
    for action in actions {
      await sender.enqueue(event(action))
    }
    await waitUntil { await preferred.events.count == actions.count }
    let sent = await preferred.events
    let fallbackEvents = await fallback.events
    precondition(sent.map(\.action) == actions && fallbackEvents.isEmpty)
    await sender.stopAll()
  }

  private static func preferredFailureWaitsForNextGesture(_ action: LivePreviewPointerAction) async {
    let preferred = RecordingBackend(minimumMoveInterval: .zero)
    let fallback = RecordingBackend(minimumMoveInterval: .zero)
    let sender = LivePreviewPointerInjector(makePreferredBackend: { _ in preferred }, fallbackBackend: fallback)
    await preparePreferredBackend(sender, preferred: preferred, fallback: fallback)
    await sender.enqueue(event(.down))
    await waitUntil { await preferred.events.count == 1 }
    await preferred.holdNextSend(failing: true)
    await sender.enqueue(event(action))
    await waitUntil { await preferred.events.count == 2 }
    if action == .move {
      await sender.enqueue(event(.move, x: 1))
      await sender.enqueue(event(.up))
    }
    for nextAction in [LivePreviewPointerAction.down, .move, .up] {
      await sender.enqueue(event(nextAction))
    }
    await preferred.release()
    await waitUntil { await fallback.events.count == 3 }
    let preferredEvents = await preferred.events
    let fallbackEvents = await fallback.events
    let stopped = await preferred.isStopped
    precondition(preferredEvents.map(\.action) == [.down, action] && stopped)
    precondition(fallbackEvents.map(\.action) == [.down, .move, .up])
    await sender.stopAll()
  }

  private static func reconnectIgnoresOldSend(_ action: LivePreviewPointerAction, failing: Bool) async {
    let old = RecordingBackend(minimumMoveInterval: .zero)
    let replacement = RecordingBackend(minimumMoveInterval: .zero)
    let fallback = RecordingBackend(minimumMoveInterval: .zero)
    let backends = BackendSequence([old, replacement])
    let sender = LivePreviewPointerInjector(makePreferredBackend: { _ in await backends.next() }, fallbackBackend: fallback)
    await preparePreferredBackend(sender, preferred: old, fallback: fallback)
    await sender.enqueue(event(.down))
    await waitUntil { await old.events.count == 1 }
    await old.holdNextSend(failing: failing)
    await sender.enqueue(event(action))
    await waitUntil { await old.events.count == 2 }
    await sender.enqueue(event(.move, x: 99))
    await sender.enqueue(event(.up))
    await sender.stopDevice("test-device")
    await sender.prepare(deviceID: "test-device")
    await old.release()
    await preparePreferredBackend(sender, preferred: replacement, fallback: fallback)
    for nextAction in [LivePreviewPointerAction.down, .move, .up] {
      await sender.enqueue(event(nextAction))
    }
    await waitUntil { await replacement.events.count == 3 }
    let oldEvents = await old.events
    let replacementEvents = await replacement.events
    let fallbackEvents = await fallback.events
    let stopped = await replacement.isStopped
    precondition(oldEvents.map(\.action) == [.down, action])
    precondition(replacementEvents.map(\.action) == [.down, .move, .up])
    precondition(fallbackEvents.isEmpty && !stopped)
    await sender.stopAll()
  }

  private static func freshRotationDoesNotQueryOnDown() async throws {
    let client = ADBClient()
    let backend = try await UInputLivePreviewPointerBackend.start(adb: ADBService(client: client), deviceID: "test-device")
    precondition(backend.minimumMoveInterval == .nanoseconds(8_333_334))
    try await backend.send(event(.down))
    try await backend.send(event(.move, x: 20))
    try await backend.send(event(.up, x: 30))
    let count = await client.queryCount
    precondition(count == 0)
    let touchscreen = await client.touchscreen
    precondition(touchscreen.actions == [.down, .move, .up])
    await backend.stop()
  }

  private static func changedSizeRefreshesBeforeDown() async throws {
    let client = ADBClient()
    await client.setViewport(ADBDisplayViewport(rotation: .rotation90, width: 200, height: 100))
    let backend = try await UInputLivePreviewPointerBackend.start(adb: ADBService(client: client), deviceID: "test-device")
    try await backend.send(event(.down, size: CGSize(width: 200, height: 100)))
    let count = await client.queryCount
    let touchscreen = await client.touchscreen
    precondition(count == 1 && touchscreen.rotations == [.rotation90])
    await backend.stop()
  }

  private static func activeDragPausesRefreshAndNextDragChecksStaleRotation() async throws {
    let client = ADBClient()
    let backend = try await UInputLivePreviewPointerBackend.start(adb: ADBService(client: client), deviceID: "test-device")
    try await backend.send(event(.down))
    await client.setViewport(ADBDisplayViewport(rotation: .rotation180))
    try await Task.sleep(for: .milliseconds(1050))
    try await backend.send(event(.move, x: 20))
    let idleQueries = await client.queryCount
    precondition(idleQueries == 0)
    try await backend.send(event(.up))
    try await backend.send(event(.down))
    let count = await client.queryCount
    let touchscreen = await client.touchscreen
    precondition(count == 1)
    precondition(touchscreen.rotations == [.rotation0, .rotation0, .rotation0, .rotation180])
    await backend.stop()
  }

  private static func idleRefreshFindsHalfTurn() async throws {
    let client = ADBClient()
    let backend = try await UInputLivePreviewPointerBackend.start(adb: ADBService(client: client), deviceID: "test-device")
    await client.setViewport(ADBDisplayViewport(rotation: .rotation180))
    await waitUntil { await client.queryCount > 0 }
    try await backend.send(event(.down))
    let touchscreen = await client.touchscreen
    precondition(touchscreen.rotations == [.rotation180])
    await backend.stop()
  }

  private static func stopDuringRefreshDoesNotSend() async throws {
    let client = ADBClient()
    await client.holdQuery()
    let backend = try await UInputLivePreviewPointerBackend.start(adb: ADBService(client: client), deviceID: "test-device")
    await waitUntil { await client.queryCount > 0 }
    let send = Task { try await backend.send(event(.down)) }
    await backend.stop()
    await client.releaseQuery()
    do {
      try await send.value
      preconditionFailure("Stopped backend accepted a pointer")
    } catch is CancellationError {}
    let touchscreen = await client.touchscreen
    precondition(touchscreen.actions.isEmpty && touchscreen.isClosed)
  }

  private static func failedRefreshDoesNotReuseOldRotation() async throws {
    let client = ADBClient()
    let backend = try await UInputLivePreviewPointerBackend.start(adb: ADBService(client: client), deviceID: "test-device")
    await client.failQueries()
    await waitUntil { await client.queryCount > 0 }
    do {
      try await backend.send(event(.down))
      preconditionFailure("Failed refresh reused an old rotation")
    } catch ADBError.protocolFailure {}
    let touchscreen = await client.touchscreen
    precondition(touchscreen.actions.isEmpty)
    await backend.stop()
  }
}
