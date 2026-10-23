import Foundation
import Testing

struct DeviceKeyboardTransportTests {
  @Test
  func wireFramesPreserveLiteralTextAndRejectOversize() throws {
    let text = "quotes '\"; $HOME `literal` %s\n😀"
    let bytes = Data(text.utf8)
    let frame = try DeviceKeyboardTransport.frame(.paste(text))
    #expect(frame.prefix(4) == Data([0, 0, 0, 3]))
    #expect(frame.dropFirst(8) == bytes)
    #expect(try DeviceKeyboardTransport.frame(.copy) == Data([0, 0, 0, 4]))
    #expect(try DeviceKeyboardTransport.frame(.key(code: 21, modifiers: 1)) == Data([0, 0, 0, 2, 0, 0, 0, 21, 0, 0, 0, 1]))
    #expect(throws: (any Error).self) {
      try DeviceKeyboardTransport.frame(.paste(String(repeating: "x", count: 1_048_577)))
    }
  }

  @Test
  func heldKeyCommandsHaveSeparateFrames() throws {
    #expect(try DeviceKeyboardTransport.frame(.keyDown(code: 3)) == Data([0, 0, 0, 5, 0, 0, 0, 3]))
    #expect(try DeviceKeyboardTransport.frame(.keyUp(code: 3)) == Data([0, 0, 0, 6, 0, 0, 0, 3]))
  }

  @Test
  func rejectsOldHelperBeforeSendingInput() async throws {
    let connection = ScriptedADBConnection(reads: [.data(Data([0, 0, 0, 1]))])
    let client = ADBClient(discoveryTimeout: .seconds(1)) { connection }
    await #expect(throws: ADBError.self) {
      _ = try await DeviceKeyboardTransport.connect(serial: "phone", adb: client) { Data([1]) }
    }
    #expect(connection.isClosed && connection.written.isEmpty)
  }

  @Test(arguments: [false, true])
  func cancellationClosesHandshakeAndPendingInput(duringHandshake: Bool) async throws {
    let connection = ScriptedADBConnection(reads: duringHandshake ? [.waitForClose] : [.data(Data([0, 0, 0, 2])), .waitForClose])
    defer { connection.close() }
    let client = ADBClient(discoveryTimeout: .seconds(1)) { connection }
    let task = Task {
      let transport = try await DeviceKeyboardTransport.connect(serial: "phone", adb: client) { Data([1]) }
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
      .data(Data([0, 0, 0, 2])), .data(response), .data(Data([0, 0, 0, 2])), .data(Data([0, 0, 0, 0]))
    ])
    defer { connection.close() }
    let client = ADBClient(discoveryTimeout: .seconds(1)) { connection }
    let transport = try await DeviceKeyboardTransport.connect(serial: "phone", adb: client) { Data([1]) }
    #expect(connection.commands.last?.contains(" keyboard 2>/dev/null") == true)
    #expect(try await transport.send(.copy) == .copied("selection 😀"))
    #expect(try await transport.send(.text("😀")) == .unsupportedText)
    #expect(try await transport.send(.text("a")) == .sent)
    let expected = try DeviceKeyboardTransport.frame(.copy)
      + DeviceKeyboardTransport.frame(.text("😀")) + DeviceKeyboardTransport.frame(.text("a"))
    #expect(connection.written == expected)
  }
}
