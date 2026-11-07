import Clocks
import Dependencies
import DependenciesTestSupport
import Foundation
import Synchronization
import Testing

@Suite("SSH process shutdown", .dependency(\.continuousClock, TestClock()))
struct SSHProcessShutdownTests {
  @Dependency(\.continuousClock, as: TestClock<Duration>.self)
  private var clock

  @Test
  func gracefulExitCompletesBeforeCleanup() async throws {
    let first = Child()
    let second = Child()
    var cleaned = false
    await SSHProcessShutdown.stop([first, second], clock: clock) {
      #expect(first.snapshot.joined == 1)
      #expect(second.snapshot.joined == 1)
      cleaned = true
    }
    #expect(cleaned)
    #expect(first.snapshot.terminations == 1)
    #expect(second.snapshot.terminations == 1)
    #expect(first.snapshot.forced == 0)
    #expect(second.snapshot.forced == 0)
    try await clock.checkSuspension()
  }

  @Test
  func timeoutForcesOnlyUnresponsiveChildrenUsingOneDeadline() async throws {
    let responsive = Child()
    let first = Child(gracefulExit: false)
    let second = Child(gracefulExit: false)
    let task = Task {
      await SSHProcessShutdown.stop([responsive, first, second], clock: clock) {}
    }
    try await first.waitUntilJoining()
    #expect(second.snapshot.terminations == 1)
    await clock.advance(by: .milliseconds(1999))
    #expect(first.snapshot.forced == 0)
    #expect(second.snapshot.forced == 0)
    await clock.advance(by: .milliseconds(1))
    await task.value
    #expect(responsive.snapshot.forced == 0)
    #expect(first.snapshot.forced == 1)
    #expect(second.snapshot.forced == 1)
    #expect(first.snapshot.joined == 1)
    #expect(second.snapshot.joined == 1)
    try await clock.checkSuspension()
  }

  @Test
  func exitedProcessStillJoinsItsTerminationCallbackBeforeCleanup() async throws {
    let child = Child(running: false)
    let cleaned = Mutex(false)
    let task = Task {
      await SSHProcessShutdown.stop([child], clock: clock) { cleaned.withLock { $0 = true } }
    }
    try await child.waitUntilJoining()
    #expect(!cleaned.withLock { $0 })
    #expect(child.snapshot.terminations == 0)
    child.complete()
    await task.value
    #expect(cleaned.withLock { $0 })
    #expect(child.snapshot.joined == 1)
    try await clock.checkSuspension()
  }

  @Test
  func forceTerminationStillWaitsForCallbackBeforeCleanup() async throws {
    let child = Child(gracefulExit: false, completesOnForce: false)
    let cleaned = Mutex(false)
    let forced = child.changed.revision
    let task = Task {
      await SSHProcessShutdown.stop([child], clock: clock) { cleaned.withLock { $0 = true } }
    }
    try await child.waitUntilJoining()
    await clock.advance(by: .seconds(2))
    var revision = forced
    while child.snapshot.forced == 0 {
      try await child.changed.wait(after: revision)
      revision = child.changed.revision
    }
    #expect(!cleaned.withLock { $0 })
    child.complete()
    await task.value
    #expect(cleaned.withLock { $0 })
    try await clock.checkSuspension()
  }

  @Test
  func cancellationStillEscalatesAndJoinsBeforeCleanup() async throws {
    let child = Child(gracefulExit: false)
    let cleaned = Mutex(false)
    let task = Task {
      await SSHProcessShutdown.stop([child], clock: clock) { cleaned.withLock { $0 = true } }
    }
    try await child.waitUntilJoining()
    task.cancel()
    #expect(!cleaned.withLock { $0 })
    await clock.advance(by: .seconds(2))
    await task.value
    #expect(child.snapshot.forced == 1)
    #expect(child.snapshot.joined == 1)
    #expect(cleaned.withLock { $0 })
    try await clock.checkSuspension()
  }

  @Test
  func exitNotifiesConcurrentAndLateWaiters() async throws {
    let child = Child(running: false)
    let first = Task { await child.waitForExit() }
    let second = Task { await child.waitForExit() }
    try await child.waitUntilJoining(2)
    first.cancel()
    child.complete()
    await first.value
    await second.value
    await child.waitForExit()
    #expect(child.snapshot.joined == 3)
  }

  @Test
  func failureBeforeLaunchStillCleansUp() async throws {
    var cleaned = false
    await SSHProcessShutdown.stop([], clock: clock) { cleaned = true }
    #expect(cleaned)
    try await clock.checkSuspension()
  }

  private final class Child: SSHChildProcess {
    struct State {
      var running: Bool
      var completed = false
      var terminations = 0
      var forced = 0
      var joining = 0
      var joined = 0
    }

    let changed = TestSignal()
    private let exit = SSHProcessExit()
    private let gracefulExit: Bool
    private let completesOnForce: Bool
    private let state: Mutex<State>

    init(running: Bool = true, gracefulExit: Bool = true, completesOnForce: Bool = true) {
      state = Mutex(State(running: running))
      self.gracefulExit = gracefulExit
      self.completesOnForce = completesOnForce
    }

    var isRunning: Bool {
      snapshot.running
    }

    var snapshot: State {
      state.withLock { $0 }
    }

    func terminate() {
      state.withLock { $0.terminations += 1 }
      if gracefulExit { complete() }
    }

    func forceTerminate() {
      state.withLock { $0.forced += 1 }
      changed.signal()
      if completesOnForce { complete() }
    }

    func complete() {
      let completed = state.withLock { state in
        guard !state.completed else { return false }
        state.running = false
        state.completed = true
        return true
      }
      if completed { exit.signal() }
    }

    func waitForExit() async {
      state.withLock { $0.joining += 1 }
      changed.signal()
      await exit.wait()
      state.withLock { $0.joined += 1 }
    }

    func waitUntilJoining(_ count: Int = 1) async throws {
      while true {
        let revision = changed.revision
        if snapshot.joining >= count { return }
        try await changed.wait(after: revision)
      }
    }
  }
}
