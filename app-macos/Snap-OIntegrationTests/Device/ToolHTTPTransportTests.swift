import Clocks
import Foundation
import NIOCore
import NIOHTTP1
import Observation
@testable import Snap_O
import Testing
import WebKit

@Suite("Tool server scheme transport", .timeLimit(.minutes(1)))
struct ToolHTTPTransportTests {
  private static let endpoint = ToolURL.api
  private static let target = DeviceTarget(serial: "phone", transportID: "1")
  private static let reference = ToolServerReference(deviceId: "phone", socketName: "snapo_network_42")

  @Test("Transport failures close the exchange")
  func propagatesTransportFailure() async throws {
    let server = FakeToolADB(failure: ToolHTTPTransportError.invalidResponse)
    let operation = try Self.operation(URLRequest(url: Self.endpoint), server: server)
    await #expect(throws: ToolHTTPTransportError.self) { try await operation.load() }
    #expect(server.cancelledConnections == 1)
  }

  @Test("Health request timeout closes an unresponsive server connection")
  func timesOut() async throws {
    let server = FakeToolADB(streaming: true)
    defer { server.close() }
    let adb = server.client()
    let input = try ToolHTTPRequestInput(request: URLRequest(url: Self.endpoint))
    let clock = TestClock()
    let operation = ToolHTTPRequestOperation(
      input: input,
      requestTimeout: .seconds(2),
      makeExchange: { _ in server },
      scheduleTimeout: { channel, duration in
        #expect(duration == .seconds(2))
        let deadline = clock.now.advanced(by: .seconds(2))
        let task = Task {
          try await clock.sleep(until: deadline)
          channel.close()
        }
        return { task.cancel() }
      }
    ) {
      try await adb.openLocalAbstract(deviceID: Self.reference.deviceId, abstractSocket: Self.reference.socketName)
    }
    let task = Task { try await operation.load() }
    try await server.waitUntil { server.requests.count == 1 }
    await clock.advance(by: .seconds(2))
    await #expect(throws: (any Error).self) { try await task.value }
    #expect(server.cancelledConnections == 1)
  }

  @Test("Device invalidation closes an active exchange")
  func invalidationClosesTransferredSocket() async throws {
    let server = FakeToolADB(streaming: true)
    defer { server.close() }
    let target = DeviceTarget(serial: "phone", transportID: "1")
    let operation = try Self.operation(URLRequest(url: Self.endpoint), server: server, adb: server.client().bound(to: target))
    let task = Task { try await operation.load() }
    try await server.waitUntil { server.requests.count == 1 }
    target.invalidate()
    await #expect(throws: (any Error).self) { try await task.value }
    #expect(server.cancelledConnections == 1)
  }

  @Test("Cancellation interrupts a stalled ADB handshake", arguments: [0, 1])
  func cancelsStalledHandshake(command: Int) async throws {
    let server = FakeToolADB(blockedCommand: command == 0 ? "host:transport:phone" : "localabstract:snapo_network_42")
    defer { server.close() }
    let operation = try Self.operation(URLRequest(url: Self.endpoint), server: server)
    let task = Task { try await operation.load() }
    try await server.connection.waitUntilBlocked()
    task.cancel()
    #expect(server.connection.isClosed)
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(server.connection.isClosed)
    #expect(server.connectionCount == (command == 0 ? 1 : 2))
    #expect(server.requests.isEmpty)
  }

  @Test("Cancellation after the ADB handshake closes the unclaimed socket")
  func cancelsBeforeSocketTransfer() async throws {
    let server = FakeToolADB(streaming: true)
    defer { server.close() }
    let adb = server.client()
    let input = try ToolHTTPRequestInput(request: URLRequest(url: Self.endpoint))
    let operation = ToolHTTPRequestOperation(input: input, makeExchange: { _ in server }) {
      let connection = try await adb.openLocalAbstract(deviceID: Self.reference.deviceId, abstractSocket: Self.reference.socketName)
      withUnsafeCurrentTask { $0?.cancel() }
      return connection
    }
    let task = Task { try await operation.load() }
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(server.connection.isClosed)
    #expect(server.requests.isEmpty)
  }

  @Test("WebKit receives normalized response headers and decoded body")
  @MainActor
  func adaptsWebKitResponse() async throws {
    let server = FakeToolADB(head: HTTPResponseHead(version: .http1_1, status: .ok, headers: [
      "Transfer-Encoding": "chunked", "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Credentials": "true",
      "Access-Control-Expose-Headers": "X-Tool-Value", "X-Tool-Value": "120", "Connection": "close, X-Hop",
      "X-Hop": "private", "Vary": "Accept", "vary": "Accept-Encoding", "X-Values": "first", "x-values": "second"
    ]), body: Data("hello".utf8))
    defer { server.close() }
    let handler = ToolSchemeHandler(makeExchange: { _ in server })
    handler.authorize(ToolHTTPService.Endpoint(
      id: UUID(), reference: Self.reference, adb: server.client(), target: Self.target
    ))
    let task = SchemeTask(URLRequest(url: Self.endpoint.appending(path: "items")))
    await handler.start(task)?.value
    #expect(task.failure == nil)
    let head = try #require(task.response)
    #expect(head.value(forHTTPHeaderField: "Transfer-Encoding") == nil)
    #expect(head.value(forHTTPHeaderField: "Connection") == nil)
    #expect(head.value(forHTTPHeaderField: "X-Hop") == nil)
    #expect(head.value(forHTTPHeaderField: "Access-Control-Allow-Origin") == "*")
    #expect(head.value(forHTTPHeaderField: "Access-Control-Allow-Credentials") == "true")
    #expect(head.value(forHTTPHeaderField: "Access-Control-Expose-Headers") == "X-Tool-Value")
    #expect(head.value(forHTTPHeaderField: "X-Tool-Value") == "120")
    #expect(head.value(forHTTPHeaderField: "Vary") == "Accept, Accept-Encoding")
    #expect(head.value(forHTTPHeaderField: "X-Values") == "first, second")
    #expect(task.body == Data("hello".utf8))
    handler.invalidate()
  }

  @Test("Stopping or disconnecting a WebKit request closes its exchange without callbacks", arguments: ["stop", "disconnect", "invalidate"])
  @MainActor
  func cancelsWebKitRequest(action: String) async throws {
    let server = FakeToolADB(streaming: true)
    defer { server.close() }
    let handler = ToolSchemeHandler(makeExchange: { _ in server })
    handler.authorize(ToolHTTPService.Endpoint(
      id: UUID(), reference: Self.reference, adb: server.client(), target: Self.target
    ))
    let task = SchemeTask(URLRequest(url: Self.endpoint.appending(path: "events")))
    let running = handler.start(task)
    try await server.waitUntil { server.requests.count == 1 }
    switch action {
    case "disconnect": handler.authorize(nil)
    case "invalidate": handler.invalidate()
    default: handler.stop(task)
    }
    await running?.value
    #expect(server.cancelledConnections == 1)
    #expect(task.failure == nil)
    #expect(task.response == nil)
    #expect(!task.finished)
  }

  @Test("other namespaces and disconnected requests are rejected")
  @MainActor
  func isolatesSessions() throws {
    let server = FakeToolADB()
    defer { server.close() }
    let handler = ToolSchemeHandler(makeExchange: { _ in server })
    let endpoint = try ToolHTTPService.Endpoint(
      id: #require(UUID(uuidString: "01234567-89ab-cdef-0123-456789abcdef")),
      reference: Self.reference,
      adb: server.client(), target: Self.target
    )
    handler.authorize(endpoint)
    let unknown = try SchemeTask(URLRequest(
      url: #require(URL(string: "snapo://other/api/items"))
    ))
    handler.start(unknown)
    #expect(unknown.failure != nil)
    handler.invalidate()
    let stale = SchemeTask(URLRequest(url: Self.endpoint.appending(path: "items")))
    handler.start(stale)
    #expect(stale.failure != nil)
    #expect(server.connectionCount == 0)
  }

  @Test("scheme requests stream data before the response finishes")
  @MainActor
  func streamsBeforeEOF() async throws {
    let event = "event: update\ndata: live\n\n"
    let server = FakeToolADB(
      head: HTTPResponseHead(version: .http1_1, status: .ok, headers: ["Content-Type": "text/event-stream"]),
      body: Data(event.utf8), streaming: true
    )
    defer { server.close() }
    let handler = ToolSchemeHandler(makeExchange: { _ in server })
    handler.authorize(ToolHTTPService.Endpoint(
      id: UUID(), reference: Self.reference, adb: server.client(), target: Self.target
    ))
    defer { handler.invalidate() }
    let request = SchemeTask(URLRequest(url: Self.endpoint.appending(path: "events")))
    let running = handler.start(request)
    try await waitForState { !request.body.isEmpty || request.failure != nil }
    #expect(request.failure == nil && !request.finished)
    #expect(request.body == Data(event.utf8))
    #expect(request.response?.value(forHTTPHeaderField: "Content-Type") == "text/event-stream")
    #expect(server.requests.map { $0.components(separatedBy: "\r\n")[0] } == ["GET /events HTTP/1.1"])
    handler.stop(request)
    await running?.value
    #expect(server.cancelledConnections == 1)
    #expect(!request.finished && request.failure == nil)
  }

  private static func operation(_ request: URLRequest, server: FakeToolADB, adb: ADBClient? = nil) throws -> ToolHTTPRequestOperation {
    let input = try ToolHTTPRequestInput(request: request)
    let client = adb ?? server.client()
    return ToolHTTPRequestOperation(input: input, makeExchange: { _ in server }) {
      try await client.openLocalAbstract(deviceID: reference.deviceId, abstractSocket: reference.socketName)
    }
  }
}

private extension ToolHTTPRequestOperation {
  func load() async throws -> Data {
    var data = Data()
    try await run(onResponse: { _ in }, onData: { data.append($0) })
    return data
  }
}

@MainActor
@Observable
private final class SchemeTask: NSObject, @preconcurrency WKURLSchemeTask {
  let request: URLRequest
  var failure: Error?
  var response: HTTPURLResponse?
  var body = Data()
  var finished = false

  init(_ request: URLRequest) {
    self.request = request
  }

  func didReceive(_ response: URLResponse) {
    self.response = response as? HTTPURLResponse
  }

  func didReceive(_ data: Data) {
    body.append(data)
  }

  func didFinish() {
    finished = true
  }

  func didFailWithError(_ error: any Error) {
    failure = error
  }
}

private final class FakeToolADB: ToolHTTPExchange, @unchecked Sendable {
  let connection: ScriptedADBConnection
  private let head: HTTPResponseHead?
  private let body: Data
  private let streaming: Bool
  private let failure: (any Error)?
  private let completion = AsyncThrowingStream<Void, Error>.makeStream()
  private let changed = TestSignal()
  private let lock = NSLock()
  private var requestLog: [String] = []
  private var connections = 0
  private var closed = false

  init(
    head: HTTPResponseHead? = nil,
    body: Data = Data(),
    streaming: Bool = false,
    failure: (any Error)? = nil,
    blockedCommand: String? = nil
  ) {
    self.head = head
    self.body = body
    self.streaming = streaming
    self.failure = failure
    connection = ScriptedADBConnection(blockedCommand: blockedCommand)
  }

  var requests: [String] {
    lock.withLock { requestLog }
  }

  var connectionCount: Int {
    lock.withLock { connections }
  }

  var cancelledConnections: Int {
    lock.withLock { closed ? 1 : 0 }
  }

  func client() -> ADBClient {
    ADBClient(discoveryTimeout: .seconds(2)) {
      let attempt = self.lock.withLock {
        self.connections += 1
        return self.connections
      }
      if attempt == 1, self.connection.blockedCommand != "host:transport:phone" {
        return ScriptedADBConnection(reads: [
          .data(Data("1: 00000002 00000000 00010000 0001 01 101 @snapo_network_42".utf8)), .end
        ])
      }
      return self.connection
    }
  }

  func close() {
    lock.withLock { closed = true }
    connection.close()
    completion.continuation.finish(throwing: CancellationError())
    changed.signal()
  }

  func scheduleTimeout(_ delay: TimeAmount) -> @Sendable () -> Void {
    Issue.record("Tests must supply their own timeout trigger")
    return {}
  }

  func run(
    isolation: isolated (any Actor)?, input: ToolHTTPRequestInput,
    onResponse: (HTTPResponseHead) async throws -> Void, onData: (Data) async throws -> Void
  ) async throws {
    lock.withLock { requestLog.append("\(input.head.method.rawValue) \(input.head.uri) HTTP/1.1") }
    changed.signal()
    if let failure { throw failure }
    if let head { try await onResponse(head) }
    if !body.isEmpty { try await onData(body) }
    if streaming {
      for try await _ in completion.stream {}
      try Task.checkCancellation()
    }
  }

  func waitUntil(_ condition: @Sendable () -> Bool) async throws {
    while true {
      let revision = changed.revision
      if condition() { return }
      try await changed.wait(after: revision)
    }
  }
}
