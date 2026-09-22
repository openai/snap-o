import Foundation
@testable import Snap_O
import Testing

@MainActor
struct LivePreviewLifecycleTests {
  @Test
  func visibilityDoesNotRestartAnExistingStream() async throws {
    let host = LifecycleHost()
    let lifecycle = host.makeLifecycle()
    lifecycle.appear()
    #expect(host.starts == 0)
    lifecycle.updateWindowVisibility(true)
    try await eventually { lifecycle.renderer == 1 }
    lifecycle.updateWindowVisibility(false)
    #expect(lifecycle.renderer == 1 && host.stops.isEmpty)
    lifecycle.updateWindowVisibility(true)
    #expect(host.starts == 1)
    lifecycle.disappear()
    await host.connection.cleanupTask?.value
    #expect(host.stops == [1])
  }

  @Test
  func lateStartupIsCleanedUpAfterDisappearance() async throws {
    let host = LifecycleHost()
    host.startGate = LifecycleGate()
    let lifecycle = host.makeLifecycle()
    lifecycle.appear()
    lifecycle.updateWindowVisibility(true)
    try await eventually { host.startGate?.entered == true }
    lifecycle.disappear()
    host.startGate?.open()
    try await eventually { host.stops == [1] }
    await host.connection.cleanupTask?.value
    #expect(lifecycle.renderer == nil)
    #expect(host.stops == [1])
  }

  @Test
  func coveringPendingStartupKeepsItsRenderer() async throws {
    let host = LifecycleHost()
    host.startGate = LifecycleGate()
    let lifecycle = host.makeLifecycle()
    lifecycle.appear()
    lifecycle.updateWindowVisibility(true)
    try await eventually { host.startGate?.entered == true }
    lifecycle.updateWindowVisibility(false)
    host.startGate?.open()
    try await eventually { lifecycle.renderer == 1 }
    #expect(!lifecycle.isWindowVisible && host.stops.isEmpty)
    lifecycle.disappear()
    await host.connection.cleanupTask?.value
  }

  @Test
  func failedStartupRequiresAnExplicitRetryAfterRemount() async throws {
    let host = LifecycleHost()
    host.failsToStart = true
    let first = host.makeLifecycle()
    first.appear()
    first.updateWindowVisibility(true)
    try await eventually { host.connection.hasFailed && !first.isConnecting }
    first.disappear()
    let replacement = host.makeLifecycle()
    replacement.appear()
    replacement.updateWindowVisibility(true)
    #expect(!replacement.isConnecting && host.starts == 1)
    host.failsToStart = false
    replacement.connect()
    try await eventually { replacement.renderer == 2 }
    #expect(!host.connection.hasFailed)
    replacement.disappear()
    await host.connection.cleanupTask?.value
  }

  @Test
  func droppedStreamReconnectsAfterCleanup() async throws {
    let host = LifecycleHost()
    let lifecycle = try await host.startPreview()
    host.stopGate = LifecycleGate()
    host.streamEnded.open()
    try await eventually { host.stopGate?.entered == true }
    #expect(host.starts == 1)
    host.stopGate?.open()
    try await eventually { lifecycle.renderer == 2 }
    #expect(!host.connection.hasFailed)
    lifecycle.disappear()
    await host.connection.cleanupTask?.value
  }

  @Test(arguments: [false, true])
  func remountWaitsForPreviousCleanup(afterFailure: Bool) async throws {
    let host = LifecycleHost()
    host.stopGate = LifecycleGate()
    let first = try await host.startPreview()
    if afterFailure {
      host.isConnected = false
      host.streamEnded.open()
      try await eventually { host.stopGate?.entered == true }
      #expect(host.connection.hasFailed)
    }
    first.disappear()
    try await eventually { host.stopGate?.entered == true }
    let second = host.makeLifecycle()
    second.appear()
    second.updateWindowVisibility(true)
    if afterFailure {
      host.isConnected = true
      second.connect()
    }
    try await eventually { second.phase == .waitingForCleanup }
    #expect(host.starts == 1)
    host.stopGate?.open()
    try await eventually { second.renderer == 2 }
    second.disappear()
    await host.connection.cleanupTask?.value
    #expect(host.stops == [1, 2])
  }

  @Test
  func displayChangeRestartsAfterCleanup() async throws {
    let host = LifecycleHost()
    let lifecycle = try await host.startPreview()
    host.stopGate = LifecycleGate()
    lifecycle.restart()
    try await eventually { lifecycle.phase == .waitingForCleanup }
    #expect(host.starts == 1)
    host.stopGate?.open()
    try await eventually { lifecycle.renderer == 2 }
    lifecycle.disappear()
    await host.connection.cleanupTask?.value
  }

  @Test
  func displayChangeRetriesTransientStartupFailures() async throws {
    let host = LifecycleHost()
    let lifecycle = try await host.startPreview()
    host.startFailuresRemaining = 2
    lifecycle.restart()
    try await eventually { lifecycle.renderer == 4 }
    #expect(!host.connection.hasFailed)
    lifecycle.disappear()
    await host.connection.cleanupTask?.value
  }

  @Test
  func displayChangeStopsRetryingPersistentFailures() async throws {
    let host = LifecycleHost()
    let lifecycle = try await host.startPreview()
    host.failsToStart = true
    lifecycle.restart()
    try await eventually { host.connection.hasFailed && !lifecycle.isConnecting }
    #expect(host.starts == 5)
  }

  @Test
  func repeatedUnexpectedDisconnectsExhaustRecovery() async throws {
    let host = LifecycleHost()
    let lifecycle = try await host.startPreview()
    host.earlyDisconnectsRemaining = 10
    host.streamEnded.open()
    try await eventually { host.connection.hasFailed && !lifecycle.isConnecting }
    #expect(host.starts == 5)
    #expect(host.stops == [1, 2, 3, 4, 5])
  }

  @Test
  func disconnectingDeviceDuringRetryStopsRecovery() async throws {
    let host = LifecycleHost()
    let lifecycle = try await host.startPreview()
    host.reconnectGate = LifecycleGate()
    host.streamEnded.open()
    try await eventually { host.reconnectGate?.entered == true }
    host.isConnected = false
    host.reconnectGate?.open()
    try await eventually { host.connection.hasFailed && !lifecycle.isConnecting }
    #expect(host.starts == 1 && host.stops == [1])
  }

  @Test(arguments: [false, true])
  func startupTimeDoesNotResetRecovery(becomesReadyBeforeDisconnect: Bool) async throws {
    let host = LifecycleHost()
    let lifecycle = try await host.startPreview()
    for attempt in 1 ... 5 {
      try await eventually { lifecycle.renderer == attempt }
      host.clock = host.clock.advanced(by: .seconds(60))
      host.readyAt = becomesReadyBeforeDisconnect ? host.clock : nil
      host.streamEnded.open()
    }
    try await eventually { host.connection.hasFailed && !lifecycle.isConnecting }
    #expect(host.starts == 5)
  }

  @Test
  func stableStreamGetsFreshRecoveryForLaterDisconnect() async throws {
    let host = LifecycleHost()
    let lifecycle = try await host.startPreview()
    host.earlyDisconnectsRemaining = 3
    host.streamEnded.open()
    try await eventually { lifecycle.renderer == 5 }
    host.clock = host.clock.advanced(by: .seconds(60))
    host.streamEnded.open()
    try await eventually { lifecycle.renderer == 6 }
    #expect(!host.connection.hasFailed)
    lifecycle.disappear()
    await host.connection.cleanupTask?.value
  }

  @Test
  func leavingPreviewCancelsUnexpectedDisconnectRecovery() async throws {
    let host = LifecycleHost()
    let lifecycle = try await host.startPreview()
    host.reconnectGate = LifecycleGate()
    host.streamEnded.open()
    try await eventually { host.reconnectGate?.entered == true }
    lifecycle.disappear()
    host.reconnectGate?.open()
    await host.connection.cleanupTask?.value
    #expect(host.starts == 1 && host.stops == [1])
    #expect(lifecycle.phase == .idle)
  }
}

@MainActor
private func eventually(_ condition: () -> Bool) async throws {
  let deadline = ContinuousClock.now.advanced(by: .seconds(3))
  while !condition(), ContinuousClock.now < deadline {
    await Task.yield()
  }
  try #require(condition(), "Lifecycle did not reach the expected state")
}

@MainActor
private final class LifecycleGate {
  private var isOpen = false
  private var waiters: [CheckedContinuation<Void, Never>] = []
  private(set) var entered = false

  func wait() async {
    entered = true
    guard !isOpen else { return }
    await withCheckedContinuation { waiters.append($0) }
  }

  func open() {
    isOpen = true
    let pending = waiters
    waiters.removeAll()
    for waiter in pending {
      waiter.resume()
    }
  }
}

@MainActor
private final class LifecycleHost {
  let connection = LivePreviewConnection()
  var isConnected = true
  var clock = ContinuousClock.now
  var readyAt: ContinuousClock.Instant?
  var starts = 0
  var stops: [Int] = []
  var failsToStart = false
  var startFailuresRemaining = 0
  var earlyDisconnectsRemaining = 0
  var reconnectGate: LifecycleGate?
  var startGate: LifecycleGate?
  var stopGate: LifecycleGate?
  var streamEnded = LifecycleGate()

  func startPreview() async throws -> LivePreviewLifecycle<Int> {
    let lifecycle = makeLifecycle()
    lifecycle.appear()
    lifecycle.updateWindowVisibility(true)
    try await eventually { lifecycle.renderer == 1 }
    return lifecycle
  }

  func makeLifecycle() -> LivePreviewLifecycle<Int> {
    LivePreviewLifecycle(connection: connection, start: {
      self.starts += 1
      await self.startGate?.wait()
      self.streamEnded = LifecycleGate()
      self.readyAt = self.clock
      if self.startFailuresRemaining > 0 {
        self.startFailuresRemaining -= 1
        return nil
      }
      if self.earlyDisconnectsRemaining > 0 {
        self.earlyDisconnectsRemaining -= 1
        self.streamEnded.open()
      }
      return self.failsToStart ? nil : self.starts
    }, stop: { renderer in
      self.stops.append(renderer)
      self.streamEnded.open()
      await self.stopGate?.wait()
    }, waitUntilStop: { _ in
      await self.streamEnded.wait()
      return nil
    }, readyAt: { _ in self.readyAt }, canReconnect: { self.isConnected }, waitBeforeReconnect: { _ in
      await self.reconnectGate?.wait()
      try Task.checkCancellation()
    }, now: { self.clock })
  }
}
