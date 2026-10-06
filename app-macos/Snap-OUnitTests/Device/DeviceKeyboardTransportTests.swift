import Foundation
import Testing

struct DeviceKeyboardTransportTests {
  @Test(arguments: [false, true])
  func cancellationClosesHandshakeAndPendingInput(duringHandshake: Bool) async throws {
    let connection = ScriptedADBConnection(reads: duringHandshake ? [.waitForClose] : [.data(Data([0, 0, 0, 1])), .waitForClose])
    defer { connection.close() }
    let client = ADBClient(discoveryTimeout: .seconds(1)) { connection }
    let task = Task {
      let transport = try await DeviceKeyboardTransport.connect(serial: "phone", adb: client, helper: { Data([1]) })
      defer { transport.close() }
      _ = try await transport.send(.copy)
    }
    defer { task.cancel() }
    try await connection.waitUntilBlocked()
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(connection.isClosed)
  }

  @Test
  func readsCopyResponseAndRejectsUnsupportedTyping() async throws {
    let response = try Data([0, 0, 0, 1]) + DeviceClipboardProtocol.frame("selection 😀")
    let connection = ScriptedADBConnection(reads: [
      .data(Data([0, 0, 0, 1])), .data(response), .data(Data([0, 0, 0, 2])), .data(Data([0, 0, 0, 0]))
    ])
    defer { connection.close() }
    let client = ADBClient(discoveryTimeout: .seconds(1)) { connection }
    let transport = try await DeviceKeyboardTransport.connect(serial: "phone", adb: client, helper: { Data([1]) })
    #expect(connection.commands.last?.contains(" keyboard 2>/dev/null") == true)
    #expect(try await transport.send(.copy) == .copied("selection 😀"))
    #expect(try await transport.send(.text("😀")) == .unsupportedText)
    #expect(try await transport.send(.text("a")) == .sent)
    let expected = try DeviceKeyboardTransport.frame(.copy)
      + DeviceKeyboardTransport.frame(.text("😀")) + DeviceKeyboardTransport.frame(.text("a"))
    #expect(connection.written == expected)
  }
}
