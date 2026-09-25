import Darwin
import Foundation
@testable import Snap_O
import Testing

@Suite(.serialized, .timeLimit(.minutes(1)))
@MainActor
struct DeviceVideoHandshakeTests {
  @Test(arguments: [false, true])
  func waitsForVideoHeaderBeforeSendingKeyframes(stopDuringHandshake: Bool) async throws {
    var descriptors: [Int32] = [0, 0]
    try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0)
    let connection = ADBSocketConnection(connectedSocket: descriptors[0])
    let peer = ADBSocketConnection(connectedSocket: descriptors[1])
    defer {
      connection.close()
      peer.close()
    }
    try peer.setIOTimeout(.seconds(3))
    let client = ADBClient(discoveryTimeout: .seconds(3)) { connection }
    let stream = DeviceVideoStream(deviceID: "synthetic", client: client)
    defer { stream.stop() }
    _ = stream.subscribe { _ in }
    let transport = try await readRequest(peer)
    #expect(transport == "host:transport:synthetic")

    // Joining during either ADB reply must not insert bytes into its framing.
    _ = stream.subscribe { _ in }
    try await expectNoCommand(peer)
    try peer.writeFully(Data("OKAY".utf8))
    let command = try await readRequest(peer)
    #expect(command.hasPrefix("exec:"))
    _ = stream.subscribe { _ in }
    try await expectNoCommand(peer)
    try peer.writeFully(Data("OKAY".utf8))
    _ = stream.subscribe { _ in }
    try await expectNoCommand(peer)

    if stopDuringHandshake {
      stream.stop()
      let ended = try await read(peer, count: 1)
      #expect(ended.isEmpty)
    } else {
      try peer.writeFully(Data("SNV1".utf8))
      let initialKeyframe = try await read(peer, count: 1)
      #expect(initialKeyframe == Data([1]))
      _ = stream.subscribe { _ in }
      let nextKeyframe = try await read(peer, count: 1)
      #expect(nextKeyframe == Data([1]))
    }
  }

  private func expectNoCommand(_ peer: ADBSocketConnection) async throws {
    let received = try await Task.detached {
      do {
        return try peer.withRequestTimeout(.milliseconds(100)) {
          try peer.readChunk(maxLength: 1)
        }
      } catch ADBError.requestTimedOut {
        return nil as Data?
      }
    }.value
    #expect(received == nil, "Keyframe commands must wait for the SNV1 header")
  }

  private func readRequest(_ peer: ADBSocketConnection) async throws -> String {
    let header = try await read(peer, count: 4)
    let text = try #require(String(data: header, encoding: .utf8))
    let length = try #require(Int(text, radix: 16))
    let payload = try await read(peer, count: length)
    return try #require(String(data: payload, encoding: .utf8))
  }

  private func read(_ peer: ADBSocketConnection, count: Int) async throws -> Data {
    try await Task.detached {
      var data = Data()
      while data.count < count, let chunk = try peer.readChunk(maxLength: count - data.count) {
        data.append(chunk)
      }
      return data
    }.value
  }
}
