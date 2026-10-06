import Foundation
import Testing

struct DeviceClipboardTransportTests {
  @Test(arguments: [false, true])
  func cancellationClosesHandshakeAndIdleStream(duringHandshake: Bool) async throws {
    let initial = try Data([0, 0, 0, 1]) + DeviceClipboardProtocol.frame("initial")
    let connection = ScriptedADBConnection(reads: duringHandshake ? [.waitForClose] : [.data(initial), .waitForClose])
    defer { connection.close() }
    let client = ADBClient(discoveryTimeout: .seconds(1)) { connection }
    let task = Task {
      try await DeviceClipboardTransport.connect(serial: "phone", adb: client, helper: { Data([1]) }) { transport in
        #expect(try await transport.getText() == "initial")
        try await transport.receive { _ in Issue.record("Unexpected clipboard event") }
      }
    }
    defer { task.cancel() }
    try await connection.waitUntilBlocked()
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(connection.isClosed)
  }
}
