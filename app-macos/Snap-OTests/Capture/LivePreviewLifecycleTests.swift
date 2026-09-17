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
  func droppedStreamRetainsFailureAndCleansUpOnce() async throws {
    let host = LifecycleHost()
    let lifecycle = host.makeLifecycle()
    lifecycle.appear()
    lifecycle.updateWindowVisibility(true)
    try await eventually { lifecycle.renderer == 1 }
    host.streamEnded.open()
    try await eventually { !lifecycle.isConnecting }
    #expect(host.connection.hasFailed && lifecycle.renderer == nil)
    lifecycle.updateWindowVisibility(false)
    lifecycle.updateWindowVisibility(true)
    #expect(host.starts == 1)
    lifecycle.disappear()
    await host.connection.cleanupTask?.value
    #expect(host.stops == [1])
  }

  @Test(arguments: [false, true])
  func remountWaitsForPreviousCleanup(afterFailure: Bool) async throws {
    let host = LifecycleHost()
    host.stopGate = LifecycleGate()
    let first = host.makeLifecycle()
    first.appear()
    first.updateWindowVisibility(true)
    try await eventually { first.renderer == 1 }
    if afterFailure {
      host.streamEnded.open()
      try await eventually { host.stopGate?.entered == true }
      #expect(host.connection.hasFailed)
    }
    first.disappear()
    try await eventually { host.stopGate?.entered == true }
    let second = host.makeLifecycle()
    second.appear()
    second.updateWindowVisibility(true)
    if afterFailure { second.connect() }
    try await eventually { second.phase == .waitingForCleanup }
    #expect(host.starts == 1)
    host.stopGate?.open()
    try await eventually { second.renderer == 2 }
    #expect(host.events.prefix(4).elementsEqual(["start", "stop", "stopped", "start"]))
    second.disappear()
    await host.connection.cleanupTask?.value
    #expect(host.stops == [1, 2])
  }

  private func eventually(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    while !condition(), ContinuousClock.now < deadline {
      await Task.yield()
    }
    try #require(condition(), "Lifecycle did not reach the expected state")
  }
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
  var starts = 0
  var stops: [Int] = []
  var events: [String] = []
  var failsToStart = false
  var startGate: LifecycleGate?
  var stopGate: LifecycleGate?
  var streamEnded = LifecycleGate()

  func makeLifecycle() -> LivePreviewLifecycle<Int> {
    LivePreviewLifecycle(connection: connection, start: {
      self.starts += 1
      self.events.append("start")
      await self.startGate?.wait()
      self.streamEnded = LifecycleGate()
      return self.failsToStart ? nil : self.starts
    }, stop: { renderer in
      self.events.append("stop")
      self.stops.append(renderer)
      self.streamEnded.open()
      await self.stopGate?.wait()
      self.events.append("stopped")
    }, waitUntilStop: { _ in
      await self.streamEnded.wait()
      return nil
    })
  }
}
