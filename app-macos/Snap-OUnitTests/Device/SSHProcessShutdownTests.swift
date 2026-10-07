import Foundation
import Synchronization
import Testing

@Suite("SSH process shutdown")
struct SSHProcessShutdownTests {
  @Test
  func gracefulExitCompletesBeforeCleanup() {
    let first = Child()
    let second = Child()
    var cleaned = false
    SSHProcessShutdown.stop([first, second]) {
      #expect(first.snapshot.joined)
      #expect(second.snapshot.joined)
      cleaned = true
    }
    #expect(cleaned)
    #expect(first.snapshot.terminations == 1)
    #expect(second.snapshot.terminations == 1)
    #expect(first.snapshot.forced == 0)
    #expect(second.snapshot.forced == 0)
  }

  @Test
  func timeoutForcesOnlyUnresponsiveChildrenUsingOneDeadline() {
    let responsive = Child()
    let blocked = Child(gracefulExit: false)
    SSHProcessShutdown.stop([responsive, blocked]) {}
    #expect(responsive.snapshot.forced == 0)
    #expect(blocked.snapshot.forced == 1)
    #expect(blocked.snapshot.joined)
    #expect(responsive.snapshot.deadline == blocked.snapshot.deadline)
  }

  @Test
  func exitedProcessStillJoinsItsTerminationCallbackBeforeCleanup() async throws {
    let child = Child(running: false, holdCompletion: true)
    let cleaned = Mutex(false)
    let entered = child.joining.revision
    let finished = TestSignal()
    let revision = finished.revision
    DispatchQueue.global().async {
      SSHProcessShutdown.stop([child]) { cleaned.withLock { $0 = true } }
      finished.signal()
    }
    defer { child.completion.signal() }
    try await child.joining.wait(after: entered)
    #expect(!cleaned.withLock { $0 })
    #expect(child.snapshot.terminations == 0)
    child.completion.signal()
    try await finished.wait(after: revision)
    #expect(cleaned.withLock { $0 })
    #expect(child.snapshot.joined)
  }

  @Test
  func failureBeforeLaunchStillCleansUp() {
    var cleaned = false
    SSHProcessShutdown.stop([]) { cleaned = true }
    #expect(cleaned)
  }

  private final class Child: SSHChildProcess {
    struct State {
      var terminations = 0
      var forced = 0
      var deadline: UInt64?
      var joined = false
    }

    let isRunning: Bool
    let joining = TestSignal()
    let completion = DispatchSemaphore(value: 0)
    private let gracefulExit: Bool
    private let holdCompletion: Bool
    private let state = Mutex(State())

    init(running: Bool = true, gracefulExit: Bool = true, holdCompletion: Bool = false) {
      isRunning = running
      self.gracefulExit = gracefulExit
      self.holdCompletion = holdCompletion
    }

    var snapshot: State {
      state.withLock { $0 }
    }

    func terminate() {
      state.withLock { $0.terminations += 1 }
    }

    func forceTerminate() {
      state.withLock { $0.forced += 1 }
    }

    func waitForExit(until deadline: DispatchTime) -> Bool {
      if deadline == .distantFuture {
        joining.signal()
        if holdCompletion { completion.wait() }
        state.withLock { $0.joined = true }
        return true
      }
      state.withLock { $0.deadline = deadline.uptimeNanoseconds }
      return gracefulExit
    }
  }
}
