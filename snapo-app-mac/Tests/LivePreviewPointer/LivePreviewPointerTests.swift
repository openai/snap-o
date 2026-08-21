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
  private var gate: CheckedContinuation<Void, Never>?
  private var holdFirstSend: Bool

  init(holdFirstSend: Bool = false, minimumMoveInterval: Duration = .nanoseconds(16_666_667)) {
    self.holdFirstSend = holdFirstSend
    self.minimumMoveInterval = minimumMoveInterval
  }

  func send(_ event: LivePreviewPointerEvent) async throws {
    events.append(event)
    if holdFirstSend {
      holdFirstSend = false
      await withCheckedContinuation { gate = $0 }
    }
  }

  func release() {
    gate?.resume()
    gate = nil
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
    try await freshRotationDoesNotQueryOnDown()
    try await activeDragPausesRefreshAndNextDragChecksStaleRotation()
    try await changedSizeRefreshesBeforeDown()
    try await idleRefreshFindsHalfTurn()
    try await stopDuringRefreshDoesNotSend()
    try await failedRefreshDoesNotReuseOldRotation()
    print("Live preview pointer tests passed (12 cases)")
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
