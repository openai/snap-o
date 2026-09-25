import Darwin
import Foundation
@testable import Snap_O
import Testing

struct DeviceClipboardTransportTests {
  @Test(arguments: [false, true])
  func cancellationClosesHandshakeAndIdleStream(duringHandshake: Bool) async throws {
    let (connection, peer) = try sockets()
    defer {
      connection.close()
      peer.close()
    }
    let ready = AsyncStream<Void>.makeStream()
    let task = Task {
      try await DeviceClipboardTransport.connect(
        serial: "phone", adb: ADBClient(discoveryTimeout: .seconds(1), connectionFactory: { connection })
      ) { transport in
        ready.continuation.yield(())
        try await transport.receive { _ in Issue.record("Unexpected clipboard event") }
      }
    }
    // Allow slow CI setup; cancellation below still has a one-second bound.
    let rescue = Task {
      try await Task.sleep(for: .seconds(30))
      ready.continuation.finish()
      connection.close()
      peer.close()
    }
    defer {
      rescue.cancel()
      task.cancel()
    }
    // Complete only the handshakes needed to reach the cancellation point.
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
      DispatchQueue.global().async {
        continuation.resume(with: Result {
          _ = try peer.readLengthPrefixedPayload()
          if !duringHandshake {
            try peer.writeFully(Data("OKAY".utf8))
            _ = try peer.readLengthPrefixedPayload()
            try peer.writeFully(Data("OKAY".utf8) + Data([0, 0, 0, 1]) + DeviceClipboardProtocol.frame("initial"))
          }
        })
      }
    }
    if !duringHandshake {
      var signals = ready.stream.makeAsyncIterator()
      try #require(await signals.next() != nil)
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

  @Test(arguments: [
    Data([0xFF, 0xFF, 0xFF, 0xFF]), // Invalid length, rejected before allocating the body.
    Data([0, 0x10, 0, 1]), // One byte over the limit.
    Data([0, 0, 0, 2, 0xC3, 0x28]), // Invalid UTF-8.
    Data([0, 0, 0, 10, 1]), // Truncated body.
    Data([0, 0]) // Truncated header.
  ])
  func rejectsMalformedFrames(_ frame: Data) throws {
    let (connection, peer) = try sockets()
    defer {
      connection.close()
      peer.close()
    }
    try peer.writeFully(frame)
    peer.close()
    #expect(throws: (any Error).self) { try DeviceClipboardProtocol.readText(connection) }
  }

  private func sockets() throws -> (ADBSocketConnection, ADBSocketConnection) {
    var descriptors: [Int32] = [0, 0]
    try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0)
    return (ADBSocketConnection(connectedSocket: descriptors[0]), ADBSocketConnection(connectedSocket: descriptors[1]))
  }
}
