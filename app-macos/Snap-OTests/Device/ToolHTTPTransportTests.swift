import Clocks
import Darwin
import Foundation
import Observation
@testable import Snap_O
import Testing
import WebKit

@Suite("Tool server scheme transport", .timeLimit(.minutes(1)))
struct ToolHTTPTransportTests {
  private static let endpoint = ToolURL.api
  private static let reference = ToolServerReference(deviceId: "phone", socketName: "snapo_network_42")

  @Test("Truncated responses and oversized headers fail", arguments: [
    "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhi",
    "HTTP/1.1 200 OK\r\nX-Large: " + String(repeating: "x", count: 17 * 1024) + "\r\n\r\n"
  ])
  func rejectsMalformedResponse(_ response: String) async throws {
    let server = FakeToolADB(plans: [.response(Data(response.utf8))])
    defer { server.close() }
    let operation = try Self.operation(
      URLRequest(url: Self.endpoint.appending(path: "items")), adb: server.client()
    )
    await #expect(throws: (any Error).self) {
      try await operation.load()
    }
  }

  @Test("Health request timeout closes an unresponsive server connection")
  func timesOut() async throws {
    let server = FakeToolADB(plans: [.stream(Data())])
    defer { server.close() }
    let adb = server.client()
    let input = try ToolHTTPRequestInput(request: URLRequest(url: Self.endpoint))
    let clock = TestClock()
    let operation = ToolHTTPRequestOperation(input: input, requestTimeout: .seconds(2), scheduleTimeout: { channel, duration in
      #expect(duration == .seconds(2))
      let task = Task {
        try await clock.sleep(for: .seconds(2))
        channel.close(promise: nil)
      }
      return { task.cancel() }
    }) {
      try await adb.openLocalAbstract(deviceID: Self.reference.deviceId, abstractSocket: Self.reference.socketName)
    }
    let task = Task { try await operation.load() }
    try await server.waitUntil { server.requests.count == 1 }
    await clock.advance(by: .seconds(2))
    await #expect(throws: (any Error).self) { try await task.value }
    try await server.waitUntil { server.cancelledConnections == 1 }
  }

  @Test("Cancellation interrupts a stalled ADB handshake", arguments: [0, 1])
  func cancelsStalledHandshake(command: Int) async throws {
    let server = FakeToolADB(plans: [.stallHandshake(command: command)])
    defer { server.close() }
    let operation = try Self.operation(URLRequest(url: Self.endpoint), adb: server.client(timeout: .seconds(10)))
    let task = Task { try await operation.load() }
    try await server.waitUntil { server.commands.count == command + 1 }
    task.cancel()
    server.expectClosedConnections()
    await #expect(throws: CancellationError.self) { try await task.value }
    try await server.waitUntil { server.cancelledConnections == 1 }
    #expect(server.connectionCount == 1)
    #expect(server.requests.isEmpty)
  }

  @Test("Cancellation after the ADB handshake closes the unclaimed socket")
  func cancelsBeforeSocketTransfer() async throws {
    let server = FakeToolADB(plans: [.stream(Data())])
    defer { server.close() }
    let adb = server.client()
    let input = try ToolHTTPRequestInput(request: URLRequest(url: Self.endpoint))
    let operation = ToolHTTPRequestOperation(input: input) {
      let connection = try await adb.openLocalAbstract(deviceID: Self.reference.deviceId, abstractSocket: Self.reference.socketName)
      withUnsafeCurrentTask { $0?.cancel() }
      return connection
    }
    let task = Task { try await operation.load() }
    await #expect(throws: CancellationError.self) { try await task.value }
    try await server.waitUntil { server.cancelledConnections == 1 }
    #expect(server.requests.isEmpty)
  }

  @Test("WebKit receives normalized response headers and decoded body")
  @MainActor
  func adaptsWebKitResponse() async throws {
    let response = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n"
      + "Access-Control-Allow-Origin: *\r\nAccess-Control-Allow-Credentials: true\r\n"
      + "Access-Control-Expose-Headers: X-Tool-Value\r\nX-Tool-Value: 120\r\n"
      + "Connection: close, X-Hop\r\nX-Hop: private\r\n"
      + "Vary: Accept\r\nvary: Accept-Encoding\r\nX-Values: first\r\nx-values: second\r\n\r\n"
      + "5\r\nhello\r\n0\r\n\r\n"
    let server = FakeToolADB(plans: [.response(Data(response.utf8))])
    defer { server.close() }
    let handler = ToolSchemeHandler()
    handler.authorize(ToolHTTPService.Endpoint(id: UUID(), reference: Self.reference, adb: server.client()))
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

  @Test("Stopping or disconnecting a WebKit request closes its socket without callbacks", arguments: ["stop", "disconnect", "invalidate"])
  @MainActor
  func cancelsWebKitRequest(action: String) async throws {
    let server = FakeToolADB(plans: [.stream(Data())])
    defer { server.close() }
    let handler = ToolSchemeHandler()
    handler.authorize(ToolHTTPService.Endpoint(id: UUID(), reference: Self.reference, adb: server.client()))
    let task = SchemeTask(URLRequest(url: Self.endpoint.appending(path: "events")))
    let running = handler.start(task)
    try await server.waitUntil { server.requests.count == 1 }
    switch action {
    case "disconnect": handler.authorize(nil)
    case "invalidate": handler.invalidate()
    default: handler.stop(task)
    }
    await running?.value
    try await server.waitUntil { server.cancelledConnections == 1 }
    #expect(task.failure == nil)
    #expect(task.response == nil)
    #expect(!task.finished)
  }

  @Test("other namespaces and disconnected requests are rejected")
  @MainActor
  func isolatesSessions() throws {
    let server = FakeToolADB(plans: [])
    defer { server.close() }
    let handler = ToolSchemeHandler()
    let endpoint = try ToolHTTPService.Endpoint(
      id: #require(UUID(uuidString: "01234567-89ab-cdef-0123-456789abcdef")),
      reference: Self.reference,
      adb: server.client()
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
    let eventHead = Data("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\n\r\n".utf8)
    let event = "event: update\ndata: live\n\n"
    let server = FakeToolADB(plans: [.stream(eventHead + Self.chunk(event))])
    defer { server.close() }
    let handler = ToolSchemeHandler()
    handler.authorize(ToolHTTPService.Endpoint(id: UUID(), reference: Self.reference, adb: server.client()))
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
    try await server.waitUntil { server.cancelledConnections == 1 }
    #expect(!request.finished && request.failure == nil)
  }

  private static func operation(_ request: URLRequest, adb: ADBClient) throws -> ToolHTTPRequestOperation {
    let input = try ToolHTTPRequestInput(request: request)
    return ToolHTTPRequestOperation(input: input) {
      try await adb.openLocalAbstract(deviceID: reference.deviceId, abstractSocket: reference.socketName)
    }
  }

  private static func response(body: String) -> Data {
    Data("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)".utf8)
  }

  private static func chunk(_ text: String) -> Data {
    Data("\(String(text.utf8.count, radix: 16))\r\n\(text)\r\n".utf8)
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

private final class FakeToolADB: @unchecked Sendable {
  enum Plan {
    case response(Data)
    case stream(Data)
    case stallHandshake(command: Int)
  }

  private let lock = NSLock()
  private let changed = TestSignal()
  private let workers = DispatchGroup()
  private var plans: [Plan]
  private var peers: [ADBSocketConnection] = []
  private var connections: [ADBSocketConnection] = []
  private var storedCommands: [String] = []
  private var storedRequests: [String] = []
  private var storedCancellations = 0

  init(plans: [Plan]) {
    self.plans = plans
  }

  var commands: [String] {
    lock.withLock { storedCommands }
  }

  var requests: [String] {
    lock.withLock { storedRequests }
  }

  var cancelledConnections: Int {
    lock.withLock { storedCancellations }
  }

  var connectionCount: Int {
    lock.withLock { peers.count }
  }

  func waitUntil(_ condition: @Sendable () -> Bool) async throws {
    while true {
      let revision = changed.revision
      if condition() { return }
      try await changed.wait(after: revision)
    }
  }

  func expectClosedConnections() {
    let active = lock.withLock { connections }
    #expect(!active.isEmpty)
    active.forEach { expectClosedConnection($0) }
  }

  func client(timeout: Duration = .seconds(1)) -> ADBClient {
    ADBClient(discoveryTimeout: timeout) { try self.connect() }
  }

  func close() {
    lock.withLock { peers.forEach { $0.close() } }
    workers.wait()
  }

  private func connect() throws -> ADBSocketConnection {
    var descriptors: [Int32] = [0, 0]
    guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
      throw POSIXError(.EIO)
    }
    // Match production sockets: cancellation must fail writes, not terminate the test process.
    var noSigPipe: Int32 = 1
    for descriptor in descriptors {
      #expect(setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size)) == 0)
    }
    let client = ADBSocketConnection(connectedSocket: descriptors[0])
    let peer = ADBSocketConnection(connectedSocket: descriptors[1])
    let plan = lock.withLock { () -> Plan in
      peers.append(peer)
      connections.append(client)
      return plans.removeFirst()
    }
    workers.enter()
    DispatchQueue.global().async {
      defer {
        peer.close()
        self.workers.leave()
      }
      do {
        for index in 0 ..< 2 {
          guard let command = try peer.readLengthPrefixedPayload(),
                let text = String(data: command, encoding: .utf8) else { return }
          self.lock.withLock { self.storedCommands.append(text) }
          self.changed.signal()
          if case .stallHandshake(command: index) = plan {
            if try peer.readChunk(maxLength: 1) == nil {
              self.lock.withLock { self.storedCancellations += 1 }
              self.changed.signal()
            }
            return
          }
          try peer.writeFully(Data("OKAY".utf8))
        }
        let request = try Self.readRequest(from: peer)
        self.lock.withLock { self.storedRequests.append(request) }
        self.changed.signal()
        switch plan {
        case .response(let data):
          try peer.writeFully(data)
        case .stream(let data):
          try peer.writeFully(data)
          if try peer.readChunk(maxLength: 1) == nil {
            self.lock.withLock { self.storedCancellations += 1 }
            self.changed.signal()
          }
        case .stallHandshake:
          Issue.record("Expected the handshake to stall")
        }
      } catch {
        if case .stream = plan {
          self.lock.withLock { self.storedCancellations += 1 }
          self.changed.signal()
        }
      }
    }
    return client
  }

  private static func readRequest(from peer: ADBSocketConnection) throws -> String {
    var bytes = Data()
    while bytes.range(of: Data("\r\n\r\n".utf8)) == nil {
      guard let chunk = try peer.readChunk(maxLength: 16 * 1024) else { throw ToolHTTPTransportError.invalidRequest }
      bytes.append(chunk)
    }
    let delimiter = bytes.range(of: Data("\r\n\r\n".utf8))!
    let head = String(decoding: bytes[..<delimiter.upperBound], as: UTF8.self)
    let lengthLine = head.components(separatedBy: "\r\n").first { $0.lowercased().hasPrefix("content-length:") }
    let length = lengthLine.flatMap { Int($0.split(separator: ":", maxSplits: 1)[1].trimmingCharacters(in: .whitespaces)) } ?? 0
    while bytes.count - delimiter.upperBound < length {
      guard let chunk = try peer.readChunk(maxLength: length) else { throw ToolHTTPTransportError.invalidRequest }
      bytes.append(chunk)
    }
    return String(decoding: bytes.prefix(delimiter.upperBound + length), as: UTF8.self)
  }
}
