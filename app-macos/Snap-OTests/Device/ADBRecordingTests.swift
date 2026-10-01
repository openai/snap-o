import Clocks
import Darwin
import Dependencies
import DependenciesTestSupport
import Foundation
@testable import Snap_O
import Testing

@Suite(.timeLimit(.minutes(1)), .dependency(\.continuousClock, TestClock()))
struct ADBRecordingTests {
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
    expectClosedConnection(fixture.connection)
  }

  @Test
  func completingTheStreamCancelsTheDeadline() async throws {
    let fixture = try Fixture()
    defer { fixture.close() }
    let task = Task {
      try await fixture.session.waitUntilStopped(timeout: .seconds(3))
    }
    await #expect(throws: SuspensionError.self) { try await clock.checkSuspension() }
    shutdown(fixture.peer, SHUT_WR)
    try await task.value
    try await clock.checkSuspension()
  }

  private struct Fixture {
    let peer: Int32
    let connection: ADBSocketConnection
    let session: RecordingSession

    init() throws {
      var sockets: [Int32] = [0, 0]
      try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets) == 0)
      peer = sockets[1]
      connection = ADBSocketConnection(connectedSocket: sockets[0])
      session = RecordingSession(
        deviceID: "test-device", remotePath: "/recording.mp4", pid: 42,
        connection: connection, startedAt: Date()
      )
    }

    func close() {
      session.close()
      Darwin.close(peer)
    }
  }
}
