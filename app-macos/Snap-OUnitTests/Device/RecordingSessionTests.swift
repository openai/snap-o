import Clocks
import ConcurrencyExtras
import Dependencies
import DependenciesTestSupport
import Foundation
import Testing

@Suite(.dependency(\.continuousClock, TestClock()))
struct RecordingSessionTests {
  @Dependency(\.continuousClock, as: TestClock<Duration>.self) private var clock

  @Test("finalization closes the recording stream when its deadline fires")
  func finalizationTimesOut() async throws {
    let fixture = try Fixture()
    defer { fixture.close() }
    let task = Task {
      try await fixture.session.waitUntilStopped(timeout: .seconds(3))
    }
    await clock.advance(by: .milliseconds(2999))
    await #expect(throws: SuspensionError.self) { try await clock.checkSuspension() }
    await clock.advance(by: .milliseconds(1))
    do {
      try await task.value
      Issue.record("Expected finalization timeout")
    } catch ADBError.requestTimedOut(let message) {
      #expect(message == "Recording finalization timed out.")
    }
    #expect(fixture.closed.value)
  }

  @Test
  func completingTheStreamCancelsTheDeadline() async throws {
    let fixture = try Fixture()
    defer { fixture.close() }
    let task = Task {
      try await fixture.session.waitUntilStopped(timeout: .seconds(3))
    }
    await #expect(throws: SuspensionError.self) { try await clock.checkSuspension() }
    fixture.stream.continuation.finish()
    try await task.value
    try await clock.checkSuspension()
  }

  @Test
  func recordedDurationStopsAtStreamCompletion() async throws {
    let fixture = try Fixture()
    defer { fixture.close() }
    await clock.advance(by: .seconds(2))
    fixture.stream.continuation.finish()
    #expect(try await fixture.session.recordedDuration() == .seconds(2))
    await clock.advance(by: .seconds(10))
    #expect(try await fixture.session.recordedDuration() == .seconds(2))
  }

  private struct Fixture {
    let stream = AsyncStream<Void>.makeStream()
    let closed = LockIsolated(false)
    let session: RecordingSession

    init(target: DeviceTarget? = nil) throws {
      let stream = stream
      let closed = closed
      session = RecordingSession(
        deviceID: target?.serial ?? "test-device", remotePath: "/recording.mp4", pid: 42,
        startedAt: Date(), target: target,
        drain: { for await _ in stream.stream {} },
        close: { closed.setValue(true)
          stream.continuation.finish()
        }
      )
    }

    func close() {
      session.close()
    }
  }
}
