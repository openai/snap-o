import Darwin
import Foundation
@testable import Snap_O
import Testing

struct ADBRecordingTests {
  @Test("finalization times out when the device keeps the recording stream open")
  func finalizationTimesOut() async throws {
    var sockets: [Int32] = [0, 0]
    guard socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets) == 0 else { throw POSIXError(.EIO) }
    defer { Darwin.close(sockets[1]) }
    let session = RecordingSession(
      deviceID: "test-device", remotePath: "/recording.mp4", pid: 42,
      connection: ADBSocketConnection(connectedSocket: sockets[0]), startedAt: Date()
    )
    defer { session.close() }
    let rescue = Task {
      // Let a broken timeout fail the test instead of leaving it stuck.
      try await Task.sleep(for: .seconds(2))
      session.close()
    }
    defer { rescue.cancel() }

    do {
      try await session.waitUntilStopped(timeout: .milliseconds(100))
      Issue.record("Expected finalization to time out")
    } catch ADBError.requestTimedOut {}
  }
}
