import Foundation

@MainActor
struct LivePreviewRequest {
  enum State { case waiting, ready, inactive }

  enum Failure: LocalizedError {
    case timedOut

    var errorDescription: String? {
      "Live Preview has not started. You can try opening it again."
    }
  }

  let state: () -> State

  func waitForFrame(
    timeout: Duration = .seconds(30),
    sleep: (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
  ) async throws {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while true {
      try Task.checkCancellation()
      guard state() == .waiting else { return }
      guard ContinuousClock.now < deadline else { throw Failure.timedOut }
      try await sleep(.milliseconds(250))
    }
  }
}
