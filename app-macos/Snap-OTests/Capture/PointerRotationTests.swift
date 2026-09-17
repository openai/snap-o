import Foundation
@testable import Snap_O
import Testing

struct PointerRotationTests {
  private static func event(
    _ action: LivePreviewPointerAction,
    size: CGSize = CGSize(width: 100, height: 200)
  ) -> LivePreviewPointerEvent {
    LivePreviewPointerEvent(
      deviceID: "test-device",
      action: action,
      source: .touchscreen,
      location: CGPoint(x: 10, y: 10),
      displaySize: size
    )
  }

  private static func waitUntil(_ condition: () async -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while await !condition() {
      try #require(ContinuousClock.now < deadline, "Timed out waiting for test state")
      try? await Task.sleep(for: .milliseconds(1))
    }
  }

  @Test(arguments: [ADBDisplayRotation.rotation90, .rotation180])
  static func rotationIsRefreshedOnlyAtGestureStart(_ rotation: ADBDisplayRotation) async throws {
    let client = PointerDevice()
    let backend = client.makeBackend()
    #expect(backend.minimumMoveInterval == .nanoseconds(8_333_334))
    try await backend.send(event(.down))
    await client.setRotation(rotation)
    try await backend.send(event(.move))
    try await backend.send(event(.up))
    let firstQueries = await client.queryCount
    #expect(firstQueries == 1)
    #expect(client.touchscreen.rotations == [.rotation0, .rotation0, .rotation0])

    // A quarter turn changes dimensions; a half turn must refresh without a size change.
    let size = rotation == .rotation90 ? CGSize(width: 200, height: 100) : CGSize(width: 100, height: 200)
    for action in [LivePreviewPointerAction.down, .move, .up] {
      try await backend.send(event(action, size: size))
    }
    let queries = await client.queryCount
    #expect(queries == 2)
    #expect(client.touchscreen.rotations == [.rotation0, .rotation0, .rotation0, rotation, rotation, rotation])
    #expect(client.touchscreen.actions == [.down, .move, .up, .down, .move, .up])
    await backend.stop()
  }

  @Test
  static func stopDuringRotationQueryDoesNotSend() async throws {
    let client = PointerDevice()
    await client.holdQuery()
    let backend = client.makeBackend()
    let send = Task { try await backend.send(event(.down)) }
    try await waitUntil { await client.queryCount == 1 }
    await backend.stop()
    await client.releaseQuery()
    do {
      try await send.value
      preconditionFailure("Stopped backend accepted a pointer")
    } catch is CancellationError {}
    let touchscreen = client.touchscreen
    #expect(touchscreen.actions.isEmpty && touchscreen.isClosed)
  }

  @Test
  static func failedRotationQueryDoesNotReuseOldRotation() async throws {
    let client = PointerDevice()
    let backend = client.makeBackend()
    try await backend.send(event(.down))
    try await backend.send(event(.up))
    await client.setRotation(.rotation180)
    await client.failQueries()
    do {
      try await backend.send(event(.down))
      preconditionFailure("Failed query reused an old rotation")
    } catch ADBError.protocolFailure {}
    let touchscreen = client.touchscreen
    let count = await client.queryCount
    #expect(count == 2 && touchscreen.actions == [.down, .up])
    await backend.stop()
  }
}

private final class PointerTouchscreen: LivePreviewTouchscreen, @unchecked Sendable {
  let supportsSynchronization = true
  let initialDisplayRotation = ADBDisplayRotation.rotation0
  private let lock = NSLock()
  private var recordedActions: [LivePreviewPointerAction] = []
  private var recordedRotations: [ADBDisplayRotation] = []
  private var closed = false

  init() {}

  var actions: [LivePreviewPointerAction] {
    lock.withLock { recordedActions }
  }

  var rotations: [ADBDisplayRotation] {
    lock.withLock { recordedRotations }
  }

  var isClosed: Bool {
    lock.withLock { closed }
  }

  func send(_ event: LivePreviewPointerEvent, rotation: ADBDisplayRotation) throws {
    try lock.withLock {
      guard !closed else { throw CancellationError() }
      recordedActions.append(event.action)
      recordedRotations.append(rotation)
    }
  }

  func close() {
    lock.withLock { closed = true }
  }
}

private actor PointerDevice {
  nonisolated let touchscreen = PointerTouchscreen()
  private(set) var queryCount = 0
  private var rotation = ADBDisplayRotation.rotation0
  private var queryGate: CheckedContinuation<Void, Never>?
  private var shouldHoldQuery = false
  private var shouldFail = false

  init() {}

  nonisolated func makeBackend() -> UInputLivePreviewPointerBackend {
    UInputLivePreviewPointerBackend(deviceID: "test-device", touchscreen: touchscreen) {
      try await self.displayRotation()
    }
  }

  func setRotation(_ rotation: ADBDisplayRotation) {
    self.rotation = rotation
  }

  func holdQuery() {
    shouldHoldQuery = true
  }

  func failQueries() {
    shouldFail = true
  }

  func releaseQuery() {
    shouldHoldQuery = false
    queryGate?.resume()
    queryGate = nil
  }

  func displayRotation() async throws -> ADBDisplayRotation {
    queryCount += 1
    if shouldHoldQuery {
      await withCheckedContinuation { queryGate = $0 }
    }
    try Task.checkCancellation()
    if shouldFail { throw ADBError.protocolFailure("Test rotation unavailable") }
    return rotation
  }
}
