import Darwin
import Foundation

protocol SSHChildProcess: AnyObject, Sendable {
  var isRunning: Bool { get }
  func terminate()
  func forceTerminate()
  func waitForExit() async
}

enum SSHProcessShutdown {
  static func stop(
    _ children: [any SSHChildProcess],
    clock: some Clock<Duration> = ContinuousClock(),
    cleanup: () -> Void
  ) async {
    for child in children where child.isRunning {
      child.terminate()
    }
    let deadline = clock.now.advanced(by: .seconds(2))
    // Cancellation of the caller must not abandon child processes or skip their grace period.
    let escalation = Task {
      do {
        try await clock.sleep(until: deadline, tolerance: nil)
      } catch { return }
      for child in children where child.isRunning {
        child.forceTerminate()
      }
    }
    for child in children {
      await child.waitForExit()
    }
    escalation.cancel()
    await escalation.value
    cleanup()
  }
}

/// Remembers process exit for every waiter, including callers that arrive after the callback.
final class SSHProcessExit: Sendable {
  private let exited = DispatchGroup()

  init() {
    exited.enter()
  }

  func signal() {
    exited.leave()
  }

  func wait() async {
    await withCheckedContinuation { continuation in
      exited.notify(queue: .global()) { continuation.resume() }
    }
  }
}

/// Joins the termination callback without blocking a worker or requiring its run loop.
final class NativeSSHChildProcess: SSHChildProcess {
  private let process: Process
  private let exited = SSHProcessExit()

  init(process: Process) throws {
    self.process = process
    let exited = exited
    process.terminationHandler = { _ in exited.signal() }
    try process.run()
  }

  var isRunning: Bool {
    process.isRunning
  }

  func terminate() {
    if process.isRunning { process.terminate() }
  }

  func forceTerminate() {
    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
  }

  func waitForExit() async {
    await exited.wait()
  }
}
