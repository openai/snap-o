import Foundation
@testable import SnapODeviceClient
import Testing

@Suite("Ordered network session")
struct NetworkSessionTests {
  @Test("preserves incoming record order")
  func preservesIncomingOrder() async {
    let transport = FakeNetworkSessionTransport()
    let session = NetworkSession(transport: transport)
    let stream = await session.records()
    let expected: [NetworkServerRecord] = [
      .network(NetworkCDPMessage(method: "Network.requestWillBeSent", snapoSequence: 1)),
      .network(NetworkCDPMessage(method: "Network.responseReceived", snapoSequence: 2)),
      .replayComplete(watermark: 2)
    ]

    let collected = Task { () -> [NetworkServerRecord] in
      var iterator = stream.makeAsyncIterator()
      var records: [NetworkServerRecord] = []
      while records.count < expected.count, let record = await iterator.next() {
        records.append(record)
      }
      return records
    }

    for record in expected {
      await transport.emit(record)
    }

    #expect(await collected.value == expected)
    await session.close()
  }

  @Test("owns command IDs and correlates out-of-order replies")
  func correlatesReplies() async throws {
    let transport = FakeNetworkSessionTransport()
    let session = NetworkSession(transport: transport)

    let firstTask = Task {
      try await session.command(method: "Network.getRequestPostData")
    }
    let firstRequest = await transport.nextSentMessage()
    let secondTask = Task {
      try await session.command(method: "Network.getResponseBody")
    }
    let secondRequest = await transport.nextSentMessage()

    #expect(firstRequest.id == 1)
    #expect(secondRequest.id == 2)

    await transport.emit(
      .network(NetworkCDPMessage(id: secondRequest.id, result: ["body": .string("second")]))
    )
    await transport.emit(
      .network(NetworkCDPMessage(id: firstRequest.id, result: ["postData": .string("first")]))
    )

    let firstReply = try await firstTask.value
    let secondReply = try await secondTask.value
    #expect(firstReply.result?["postData"] == .string("first"))
    #expect(secondReply.result?["body"] == .string("second"))
    await session.close()
  }

  @Test("times out a command without closing the session")
  func timesOutCommand() async throws {
    let transport = FakeNetworkSessionTransport()
    let session = NetworkSession(
      transport: transport,
      defaultCommandTimeout: .milliseconds(30)
    )

    let command = Task {
      try await session.command(method: "Network.getResponseBody")
    }
    _ = await transport.nextSentMessage()

    do {
      _ = try await command.value
      Issue.record("Expected the command to time out")
    } catch let error as NetworkSessionError {
      #expect(error == .commandTimedOut("Network.getResponseBody"))
    } catch {
      Issue.record("Unexpected error: \(error)")
    }

    try await session.send(method: SnapONetworkProtocol.Method.startStream)
    await session.close()
  }

  @Test("cancellation removes the pending command")
  func cancelsCommand() async {
    let transport = FakeNetworkSessionTransport()
    let session = NetworkSession(transport: transport)
    let command = Task {
      try await session.command(method: "Network.getResponseBody")
    }
    _ = await transport.nextSentMessage()

    command.cancel()
    do {
      _ = try await command.value
      Issue.record("Expected command cancellation")
    } catch is CancellationError {
      // Expected.
    } catch {
      Issue.record("Unexpected error: \(error)")
    }

    await session.close()
  }

  @Test("close is idempotent, finishes records, and fails pending work")
  func closesIdempotently() async {
    let transport = FakeNetworkSessionTransport()
    let session = NetworkSession(transport: transport)
    let stream = await session.records()
    let command = Task {
      try await session.command(method: "Network.getResponseBody")
    }
    _ = await transport.nextSentMessage()

    async let firstClose: Void = session.close()
    async let secondClose: Void = session.close()
    _ = await (firstClose, secondClose)

    do {
      _ = try await command.value
      Issue.record("Expected close to fail the pending command")
    } catch let error as NetworkSessionError {
      #expect(error == .closed)
    } catch {
      Issue.record("Unexpected error: \(error)")
    }

    var iterator = stream.makeAsyncIterator()
    #expect(await iterator.next() == nil)
    #expect(await session.recordStreamFailure() == nil)
    #expect(await transport.closeCallCount == 1)
  }

  @Test("closes instead of growing without bound when its consumer stalls")
  func closesOnRecordBackpressure() async {
    let transport = FakeNetworkSessionTransport()
    let session = NetworkSession(transport: transport)
    _ = await session.records()

    for sequence in 1 ... 4097 {
      await transport.emit(
        .network(
          NetworkCDPMessage(
            method: "Network.loadingFinished",
            snapoSequence: UInt64(sequence)
          )
        )
      )
    }

    while await transport.closeCallCount == 0 {
      await Task.yield()
    }
    #expect(await transport.closeCallCount == 1)
    #expect(
      await session.recordStreamFailure() == .transportFailed(
        "The network record consumer could not keep up. Reconnect to obtain a fresh replay."
      )
    )
  }

  @Test("exposes transport failures after the record stream ends")
  func exposesTransportFailure() async {
    let transport = FakeNetworkSessionTransport()
    let session = NetworkSession(transport: transport)
    let stream = await session.records()
    await transport.fail(TestTransportError.disconnected)

    var iterator = stream.makeAsyncIterator()
    #expect(await iterator.next() == nil)
    #expect(
      await session.recordStreamFailure() == .transportFailed(
        TestTransportError.disconnected.localizedDescription
      )
    )
  }
}

private enum TestTransportError: LocalizedError {
  case disconnected

  var errorDescription: String? {
    "Test transport disconnected."
  }
}

private actor FakeNetworkSessionTransport: NetworkSessionTransport {
  private let recordStream: AsyncThrowingStream<NetworkServerRecord, Error>
  private let recordContinuation: AsyncThrowingStream<NetworkServerRecord, Error>.Continuation
  private var queuedSentMessages: [NetworkCDPMessage] = []
  private var sentMessageWaiters: [CheckedContinuation<NetworkCDPMessage, Never>] = []
  private(set) var closeCallCount = 0

  init() {
    (recordStream, recordContinuation) = AsyncThrowingStream.makeStream(
      of: NetworkServerRecord.self,
      throwing: Error.self,
      bufferingPolicy: .unbounded
    )
  }

  func records() -> AsyncThrowingStream<NetworkServerRecord, Error> {
    recordStream
  }

  func send(_ message: NetworkCDPMessage) {
    if sentMessageWaiters.isEmpty {
      queuedSentMessages.append(message)
    } else {
      sentMessageWaiters.removeFirst().resume(returning: message)
    }
  }

  func close() {
    closeCallCount += 1
    recordContinuation.finish()
  }

  func emit(_ record: NetworkServerRecord) {
    recordContinuation.yield(record)
  }

  func fail(_ error: any Error) {
    recordContinuation.finish(throwing: error)
  }

  func nextSentMessage() async -> NetworkCDPMessage {
    if !queuedSentMessages.isEmpty {
      return queuedSentMessages.removeFirst()
    }
    return await withCheckedContinuation { continuation in
      sentMessageWaiters.append(continuation)
    }
  }
}
