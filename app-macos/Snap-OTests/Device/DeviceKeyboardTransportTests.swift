import Darwin
import Foundation
@testable import Snap_O
import Testing

@Suite(.timeLimit(.minutes(1)))
struct DeviceKeyboardTransportTests {
  @Test(arguments: [false, true])
  func cancellationClosesHandshakeAndPendingInput(duringHandshake: Bool) async throws {
    let (connection, peer) = try sockets()
    defer {
      connection.close()
      peer.close()
    }
    let task = Task {
      let transport = try await DeviceKeyboardTransport.connect(
        serial: "phone", adb: ADBClient(discoveryTimeout: .seconds(1), connectionFactory: { connection })
      )
      defer { transport.close() }
      _ = try await transport.send(.copy)
    }
    let rescue = Task {
      try await Task.sleep(for: .seconds(3))
      connection.close()
      peer.close()
    }
    defer {
      rescue.cancel()
      task.cancel()
    }
    try await perform {
      _ = try peer.readLengthPrefixedPayload()
      if !duringHandshake {
        try peer.writeFully(Data("OKAY".utf8))
        _ = try peer.readLengthPrefixedPayload()
        try peer.writeFully(Data("OKAY".utf8) + Data([0, 0, 0, 1]))
        #expect(try DeviceClipboardProtocol.readNumber(peer) == 4)
      }
    }
    let start = ContinuousClock.now
    task.cancel()
    do {
      try await task.value
      Issue.record("Expected cancellation")
    } catch {
      #expect(start.duration(to: .now) < .seconds(1))
    }
  }

  @Test
  func readsCopyResponseAndRejectsUnsupportedTyping() async throws {
    let (connection, peer) = try sockets()
    defer {
      connection.close()
      peer.close()
    }
    let task = Task {
      try await DeviceKeyboardTransport.connect(
        serial: "phone", adb: ADBClient(discoveryTimeout: .seconds(1), connectionFactory: { connection })
      )
    }
    try await perform {
      _ = try peer.readLengthPrefixedPayload()
      try peer.writeFully(Data("OKAY".utf8))
      let payload = try peer.readLengthPrefixedPayload()
      let command = try #require(payload)
      #expect(String(data: command, encoding: .utf8)?.contains(" keyboard 2>/dev/null") == true)
      try peer.writeFully(Data("OKAY".utf8) + Data([0, 0, 0, 1]))
    }
    let transport = try await task.value
    defer { transport.close() }
    try peer.writeFully(Data([0, 0, 0, 1]) + DeviceClipboardProtocol.frame("selection 😀"))
    #expect(try await transport.send(.copy) == .copied("selection 😀"))
    #expect(try DeviceClipboardProtocol.readNumber(peer) == 4)
    try peer.writeFully(Data([0, 0, 0, 2]))
    #expect(try await transport.send(.text("😀")) == .unsupportedText)
    #expect(try DeviceClipboardProtocol.readNumber(peer) == 1)
    #expect(try DeviceClipboardProtocol.readText(peer) == "😀")
    try peer.writeFully(Data([0, 0, 0, 0]))
    #expect(try await transport.send(.text("a")) == .sent)
    #expect(try DeviceClipboardProtocol.readNumber(peer) == 1)
    #expect(try DeviceClipboardProtocol.readText(peer) == "a")
  }

  private func perform(_ body: @escaping @Sendable () throws -> Void) async throws {
    try await withCheckedThrowingContinuation { continuation in
      DispatchQueue.global().async { continuation.resume(with: Result(catching: body)) }
    }
  }

  private func sockets() throws -> (ADBSocketConnection, ADBSocketConnection) {
    var descriptors: [Int32] = [0, 0]
    try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0)
    return (ADBSocketConnection(connectedSocket: descriptors[0]), ADBSocketConnection(connectedSocket: descriptors[1]))
  }
}
