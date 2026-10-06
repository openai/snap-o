import Dependencies
import Foundation

/// Gives cleanup a deadline and replies once, even when late cleanup ignores cancellation.
@MainActor
final class AppTermination {
  enum Outcome: Equatable {
    case completed
    case timedOut(unfinished: [String])
  }

  private(set) var outcome: Outcome?
  var isRunning: Bool {
    cleanupTask != nil
  }

  private var cleanupTask: Task<Void, Never>?
  private var deadlineTask: Task<Void, Never>?
  @Dependency(\.continuousClock)
  private var clock

  func begin(
    cleanup: @escaping @MainActor () async -> Void,
    unfinishedWork: @escaping @MainActor () -> [String],
    reply: @escaping @MainActor (Outcome) -> Void
  ) {
    guard cleanupTask == nil, outcome == nil else { return }
    cleanupTask = Task {
      await cleanup()
      finish(.completed, reply: reply)
    }
    deadlineTask = Task { [clock] in
      do { try await clock.sleep(for: .seconds(5)) } catch { return }
      guard !Task.isCancelled else { return }
      finish(.timedOut(unfinished: unfinishedWork()), reply: reply)
    }
  }

  private func finish(_ result: Outcome, reply: (Outcome) -> Void) {
    guard outcome == nil else { return }
    outcome = result
    cleanupTask?.cancel()
    cleanupTask = nil
    deadlineTask?.cancel()
    deadlineTask = nil
    reply(result)
  }
}
