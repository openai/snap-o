import Foundation
@testable import SnapODeviceClient
import Testing

@Suite("HTTP network session")
struct NetworkSessionTests {
  @Test("joins HTTP history with buffered live events and drops late duplicates")
  func joinsHistoryAndLiveEvents() async throws {
    let transport = FakeNetworkSessionTransport()
    let session = NetworkSession(transport: transport)
    let stream = await session.records()
    let first = event(1)
    let second = event(2)
    let third = event(3)
    let fourth = event(4)
    let collected = Task { () -> [NetworkServerRecord] in
      var records: [NetworkServerRecord] = []
      for await record in stream {
        records.append(record)
        if records.count == 5 { break }
      }
      return records
    }
    let start = Task { try await session.startStream() }
    await transport.waitForSnapshot()
    await transport.emit(first)
    await transport.emit(third)
    await transport.completeSnapshot(records: [first, second], watermark: 2)
    try await start.value
    await transport.emit(second)
    await transport.emit(fourth)
    #expect(await collected.value == [first, second, .replayComplete(watermark: 2), third, fourth])
    await session.close()
  }

  @Test("stopping during HTTP history prevents stale snapshot delivery")
  func stopsDuringHistory() async throws {
    let transport = FakeNetworkSessionTransport()
    let session = NetworkSession(transport: transport)
    let stream = await session.records()
    let collected = Task { await stream.reduce(into: [NetworkServerRecord]()) { $0.append($1) } }
    let start = Task { try await session.startStream() }
    await transport.waitForSnapshot()
    await session.stopStream()
    await transport.completeSnapshot(records: [event(1)], watermark: 1)
    await #expect(throws: CancellationError.self) { try await start.value }
    await session.close()
    #expect(await collected.value.isEmpty)
    #expect(await transport.stopCount == 1)
  }

  @Test("concurrent starts share the same subscription and snapshot")
  func coalescesStarts() async throws {
    let transport = FakeNetworkSessionTransport()
    let session = NetworkSession(transport: transport)
    let first = Task { try await session.startStream() }
    await transport.waitForSnapshot()
    let second = Task { try await session.startStream() }
    await transport.completeSnapshot(records: [], watermark: 0)
    try await first.value
    try await second.value
    #expect(await transport.startCount == 1)
    await session.close()
  }

  @Test("body reads use independent HTTP operations and do not require a stream")
  func readsBodiesWithoutStartingEvents() async throws {
    let transport = FakeNetworkSessionTransport()
    let session = NetworkSession(transport: transport)
    async let request = session.requestBody(requestID: "request-1")
    async let response = session.responseBody(requestID: "request-1")
    #expect(try await request == "request data")
    #expect(try await response == NetworkResponseBody(body: "response data", base64Encoded: false))
    #expect(await transport.startCount == 0)
    await session.close()
    await #expect(throws: NetworkSessionError.closed) { try await session.responseBody(requestID: "request-1") }
  }

  @Test("event stream errors remain visible to the session consumer")
  func reportsStreamFailure() async {
    let transport = FakeNetworkSessionTransport()
    let session = NetworkSession(transport: transport)
    let stream = await session.records()
    await transport.fail()
    for await _ in stream {}
    #expect(await session.recordStreamFailure() != nil)
    #expect(await transport.isClosed)
  }

  @Test("a slow record consumer causes a visible failure instead of silent data loss")
  func boundsConsumerBuffer() async throws {
    let transport = FakeNetworkSessionTransport()
    let session = NetworkSession(transport: transport)
    let stream = await session.records()
    let start = Task { try await session.startStream() }
    await transport.waitForSnapshot()
    await transport.completeSnapshot(records: (1 ... 4097).map { event(UInt64($0)) }, watermark: 4097)
    await #expect(throws: (any Error).self) { try await start.value }
    for await _ in stream {}
    #expect(await session.recordStreamFailure()?.localizedDescription.contains("could not keep up") == true)
    await session.close()
  }

  @Test("SSE decoding handles comments, CRLF, fragmented UTF-8, and complete-event boundaries")
  func decodesSSE() throws {
    var decoder = NetworkSSEDecoder()
    let wire = ": keep-alive\r\n\r\nid: 42\r\ndata: {\"method\":\"Network.loadingFinished\",\"params\":{\"requestId\":\"🙂\"},\"snapoSequence\":42}\r\n\r\n"
    var records: [NetworkCDPMessage] = []
    for byte in wire.utf8 {
      if let record = try decoder.append(byte) { records.append(record) }
    }
    #expect(records.count == 1)
    #expect(records.first?.snapoSequence == 42)
    #expect(records.first?.params?["requestId"]?.stringValue == "🙂")
  }

  @Test("SSE decoder rejects corrupt UTF-8 and mismatched sequence ids")
  func rejectsInvalidSSE() {
    #expect(throws: (any Error).self) {
      var decoder = NetworkSSEDecoder()
      for byte: UInt8 in [100, 97, 116, 97, 58, 32, 255, 10] {
        _ = try decoder.append(byte)
      }
    }
    #expect(throws: (any Error).self) {
      var decoder = NetworkSSEDecoder()
      for byte in "id: 2\ndata: {\"method\":\"Network.loadingFinished\",\"snapoSequence\":1}\n\n".utf8 {
        _ = try decoder.append(byte)
      }
    }
  }

  private func event(_ sequence: UInt64) -> NetworkServerRecord {
    .network(NetworkCDPMessage(method: "Network.loadingFinished", snapoSequence: sequence))
  }
}

private actor FakeNetworkSessionTransport: NetworkSessionTransport {
  private let stream: AsyncThrowingStream<NetworkServerRecord, Error>
  private let continuation: AsyncThrowingStream<NetworkServerRecord, Error>.Continuation
  private var snapshot: CheckedContinuation<([NetworkServerRecord], UInt64), Never>?
  private var snapshotWaiter: CheckedContinuation<Void, Never>?
  private(set) var isClosed = false
  private(set) var startCount = 0
  private(set) var stopCount = 0

  init() {
    (stream, continuation) = AsyncThrowingStream.makeStream()
  }

  func records() -> AsyncThrowingStream<NetworkServerRecord, Error> {
    stream
  }

  func startEvents() {
    startCount += 1
  }

  func stopEvents() {
    stopCount += 1
  }

  func requestBody(requestID: String) -> String {
    "request data"
  }

  func responseBody(requestID: String) -> NetworkResponseBody {
    NetworkResponseBody(body: "response data", base64Encoded: false)
  }

  func emit(_ record: NetworkServerRecord) {
    continuation.yield(record)
  }

  func fail() {
    continuation.finish(throwing: NetworkSessionError.transportFailed("Test stream failure"))
  }

  func close() {
    isClosed = true
    continuation.finish()
  }

  func replaySnapshot(_ receive: @Sendable (NetworkServerRecord) async throws -> Void) async throws -> UInt64 {
    let (records, watermark) = await withCheckedContinuation { continuation in
      snapshot = continuation
      snapshotWaiter?.resume()
      snapshotWaiter = nil
    }
    for record in records {
      try await receive(record)
    }
    return watermark
  }

  func waitForSnapshot() async {
    if snapshot != nil { return }
    await withCheckedContinuation { snapshotWaiter = $0 }
  }

  func completeSnapshot(records: [NetworkServerRecord], watermark: UInt64) {
    snapshot?.resume(returning: (records, watermark))
    snapshot = nil
  }
}
