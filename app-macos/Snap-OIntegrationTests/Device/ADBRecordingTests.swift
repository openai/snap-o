import Clocks
import ConcurrencyExtras
import DependenciesTestSupport
import Foundation
@testable import Snap_O
import Testing

@Suite(.dependency(\.continuousClock, TestClock()))
struct ADBRecordingTests {
  @Test
  func oldSessionCleanupCannotConnectToReplacement() async throws {
    let target = DeviceTarget(serial: "reused-serial", transportID: "7")
    let session = RecordingSession(
      deviceID: target.serial, remotePath: "/recording.mp4", pid: 42, startedAt: Date(), target: target,
      drain: {}, close: {}
    )
    defer { session.close() }
    target.invalidate()
    let attempts = LockIsolated(0)
    let client = ADBClient(discoveryTimeout: .seconds(2)) {
      attempts.withValue { $0 += 1 }
      throw ADBError.serverUnavailable("Unexpected connection attempt")
    }
    await #expect(throws: (any Error).self) { try await client.signalScreenrecordStop(session: session) }
    await #expect(throws: (any Error).self) { try await client.removeScreenrecord(session: session) }
    let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: destination) }
    await #expect(throws: (any Error).self) {
      try await client.downloadScreenrecord(session: session, savingTo: destination)
    }
    #expect(attempts.value == 0, "Old sessions must reject cleanup before opening another ADB connection")
  }
}
