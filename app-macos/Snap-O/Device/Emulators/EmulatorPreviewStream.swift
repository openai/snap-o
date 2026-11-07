import Dependencies
import Foundation

/// Selects native or scaled streams without tying size discovery to transport failure.
enum EmulatorPreviewStream {
  struct DisplayChange {
    let size: CGSize?
  }

  static func run(
    requestedSize: LivePreviewFrameSize,
    isolation: isolated (any Actor)? = #isolation,
    readDisplaySize: () async throws -> CGSize?,
    receiveFrames: (LivePreviewFrameSize, CGSize?) async throws -> DisplayChange?
  ) async throws {
    try Task.checkCancellation()
    var nativeSize: CGSize?
    if case .preview = requestedSize {
      nativeSize = try await readSize(readDisplaySize)
    }
    while true {
      try Task.checkCancellation()
      let change = try await receiveFrames(requestedSize.capped(to: nativeSize), nativeSize)
      try Task.checkCancellation()
      guard let change else { return }
      nativeSize = change.size
    }
  }

  static func readSize(
    _ read: () async throws -> CGSize?,
    isolation: isolated (any Actor)? = #isolation
  ) async throws -> CGSize? {
    do {
      let size = try await read()
      try Task.checkCancellation()
      return size
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      try Task.checkCancellation()
      return nil
    }
  }
}

/// Counts only an active startup attempt, ending permanently after the first frame or stop.
@MainActor
final class EmulatorPreviewStartupDeadline {
  private let clock: AnyClock<Duration>
  private let expired: () -> Void
  private var active = false
  private var finished = false
  private var task: Task<Void, Never>?

  init(expired: @escaping () -> Void) {
    @Dependency(\.continuousClock)
    var clock
    self.clock = AnyClock(clock)
    self.expired = expired
  }

  func setActive(_ active: Bool) {
    guard !finished, self.active != active else { return }
    self.active = active
    task?.cancel()
    guard active else { return }
    let previous = task
    let deadline = clock.now.advanced(by: .seconds(15))
    task = Task {
      await previous?.value
      do { try await clock.sleep(until: deadline) } catch { return }
      guard !Task.isCancelled else { return }
      finish()
      expired()
    }
  }

  func finish() {
    finished = true
    task?.cancel()
  }

  func waitUntilStopped() async {
    await task?.value
  }
}
