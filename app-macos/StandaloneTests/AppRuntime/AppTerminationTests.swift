import Clocks
import Dependencies
import Foundation

@MainActor
enum AppTerminationTests {
  static func run() async throws {
    try await completionCancelsDeadline()
    try await deadlineReportsCurrentWorkAndRepliesOnce()
    print("App termination deadline tests passed")
  }

  static func completionCancelsDeadline() async throws {
    let clock = TestClock()
    try await withDependencies { $0.continuousClock = clock } operation: {
      let termination = AppTermination()
      let cleanup = TestGate()
      let replies = TestValue<[AppTermination.Outcome]>([])
      termination.begin {
        await cleanup.wait()
      } unfinishedWork: {
        ["workspaces"]
      } reply: { replies.value.append($0) }
      termination.begin {
        preconditionFailure("Repeated termination must not restart cleanup")
      } unfinishedWork: { [] } reply: { _ in
        preconditionFailure("Repeated termination must not add another reply")
      }
      await waitForActorTestState { await cleanup.waitCount == 1 }
      precondition(termination.isRunning)
      await cleanup.open()
      await waitForObservedTestState { replies.value == [.completed] }
      precondition(termination.outcome == .completed && !termination.isRunning)
      try await clock.checkSuspension()
      await clock.advance(by: .seconds(5))
      precondition(replies.value == [.completed])
    }
  }

  static func deadlineReportsCurrentWorkAndRepliesOnce() async throws {
    let clock = TestClock()
    try await withDependencies { $0.continuousClock = clock } operation: {
      let termination = AppTermination()
      let cleanup = TestGate()
      let finished = TestValue(false)
      let pending = TestValue(["workspaces", "file exports"])
      let replies = TestValue<[AppTermination.Outcome]>([])
      termination.begin {
        await cleanup.wait()
        finished.value = true
      } unfinishedWork: {
        pending.value
      } reply: { replies.value.append($0) }
      await waitForActorTestState { await cleanup.waitCount == 1 }
      pending.value = ["file exports"]
      await clock.advance(by: .seconds(4))
      precondition(termination.outcome == nil && replies.value.isEmpty)
      await clock.advance(by: .seconds(1))
      let expected = AppTermination.Outcome.timedOut(unfinished: ["file exports"])
      await waitForObservedTestState { replies.value == [expected] }
      precondition(termination.outcome == expected && !termination.isRunning && !finished.value)
      await cleanup.open()
      await waitForObservedTestState { finished.value }
      precondition(replies.value == [expected], "Late cleanup must not send a second reply")
      try await clock.checkSuspension()
    }
  }
}
