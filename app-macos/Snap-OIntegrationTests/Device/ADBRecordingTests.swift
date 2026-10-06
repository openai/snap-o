import Clocks
import ConcurrencyExtras
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

  @Test
  func recordedDurationStopsAtStreamCompletion() async throws {
    let fixture = try Fixture()
    defer { fixture.close() }
    await clock.advance(by: .seconds(2))
    shutdown(fixture.peer, SHUT_WR)
    #expect(try await fixture.session.recordedDuration() == .seconds(2))
    await clock.advance(by: .seconds(10))
    #expect(try await fixture.session.recordedDuration() == .seconds(2))
  }

  @Test
  func oldSessionCleanupCannotConnectToReplacement() async throws {
    let target = DeviceTarget(serial: "reused-serial", transportID: "7")
    let fixture = try Fixture(target: target)
    defer { fixture.close() }
    target.invalidate()
    let attempts = LockIsolated(0)
    let client = ADBClient(discoveryTimeout: .seconds(2)) {
      attempts.withValue { $0 += 1 }
      throw ADBError.serverUnavailable("Unexpected connection attempt")
    }
    await #expect(throws: (any Error).self) { try await client.signalScreenrecordStop(session: fixture.session) }
    await #expect(throws: (any Error).self) { try await client.removeScreenrecord(session: fixture.session) }
    let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: destination) }
    await #expect(throws: (any Error).self) {
      try await client.downloadScreenrecord(session: fixture.session, savingTo: destination)
    }
    #expect(attempts.value == 0, "Old sessions must reject cleanup before opening another ADB connection")
  }

  private struct Fixture {
    let peer: Int32
    let connection: ADBSocketConnection
    let session: RecordingSession

    init(target: DeviceTarget? = nil) throws {
      var sockets: [Int32] = [0, 0]
      try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets) == 0)
      peer = sockets[1]
      connection = ADBSocketConnection(connectedSocket: sockets[0])
      session = RecordingSession(
        deviceID: target?.serial ?? "test-device", remotePath: "/recording.mp4", pid: 42,
        connection: connection, startedAt: Date(), target: target
      )
    }

    func close() {
      session.close()
      Darwin.close(peer)
    }
  }
}
