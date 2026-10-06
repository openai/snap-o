import Foundation

final class RecordingSession: @unchecked Sendable {
  let deviceID: String
  private let lock = NSLock()
  private var result: Result<Void, Error>?
  private var waiters: [CheckedContinuation<Void, Error>] = []

  init(deviceID: String) {
    self.deviceID = deviceID
  }

  func recordedDuration() async throws -> Duration {
    .seconds(1)
  }

  func waitUntilStopped() async throws {
    try await withCheckedThrowingContinuation { continuation in
      lock.withLock {
        if let result { continuation.resume(with: result) } else { waiters.append(continuation) }
      }
    }
  }

  func waitUntilStopped(timeout _: Duration) async throws {
    try await waitUntilStopped()
  }

  func end(error: Error? = nil) {
    lock.withLock {
      guard result == nil else { return }
      let outcome: Result<Void, Error> = error.map { .failure($0) } ?? .success(())
      result = outcome
      for waiter in waiters {
        waiter.resume(with: outcome)
      }
      waiters.removeAll()
    }
  }

  func close() {
    end()
  }
}
