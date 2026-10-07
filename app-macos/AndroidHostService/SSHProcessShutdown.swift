import Darwin
import Foundation

protocol SSHChildProcess: AnyObject, Sendable {
  var isRunning: Bool { get }
  func terminate()
  func forceTerminate()
  func waitForExit(until deadline: DispatchTime) -> Bool
}

enum SSHProcessShutdown {
  static func stop(_ children: [any SSHChildProcess], cleanup: () -> Void) {
    for child in children where child.isRunning {
      child.terminate()
    }
    let deadline = DispatchTime.now() + 2
    for child in children where !child.waitForExit(until: deadline) {
      child.forceTerminate()
    }
    for child in children {
      _ = child.waitForExit(until: .distantFuture)
    }
    cleanup()
  }
}

/// Joins the termination callback without requiring the launch worker's run loop.
final class NativeSSHChildProcess: SSHChildProcess {
  private let process: Process
  private let exited = DispatchGroup()

  init(process: Process) throws {
    self.process = process
    let exited = exited
    exited.enter()
    process.terminationHandler = { _ in exited.leave() }
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

  func waitForExit(until deadline: DispatchTime) -> Bool {
    exited.wait(timeout: deadline) == .success
  }
}
