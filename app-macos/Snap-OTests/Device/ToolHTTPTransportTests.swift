import AppKit
import Darwin
import Foundation
import NIOHTTP1
@testable import Snap_O
import Testing
import WebKit

@Suite("Tool server scheme transport", .serialized)
struct ToolHTTPTransportTests {
  private static let endpoint = ToolURL.api
  private static let reference = ToolServerReference(deviceId: "phone", socketName: "snapo_network_42")

  @Test("GET and JSON POST preserve request details")
  func forwardsRequests() async throws {
    let server = FakeToolADB(plans: [
      .response([.init(data: Self.response(body: #"{"method":"GET"}"#))]),
      .response([.init(data: Self.response(body: #"{"method":"POST"}"#))])
    ])
    defer { server.close() }
    let adb = server.client()

    var get = URLRequest(url: Self.endpoint.appending(path: "items").appending(queryItems: [.init(name: "page", value: "2")]))
    get.setValue("application/json", forHTTPHeaderField: "Accept")
    let getResult = try await Self.operation(get, adb: adb).load(maximumBytes: 1024)
    #expect(getResult.0.status == .ok)
    #expect(String(decoding: getResult.1, as: UTF8.self) == #"{"method":"GET"}"#)

    var post = URLRequest(url: Self.endpoint.appending(path: "items"))
    post.httpMethod = "POST"
    post.httpBody = Data(#"{"enabled":true}"#.utf8)
    post.setValue("application/json", forHTTPHeaderField: "Content-Type")
    let postResult = try await Self.operation(post, adb: adb).load(maximumBytes: 1024)
    #expect(postResult.0.status == .ok)

    let requests = server.requests
    #expect(requests.count == 2)
    #expect(requests[0].hasPrefix("GET /items?page=2 HTTP/1.1\r\n"))
    #expect(requests[0].contains("Accept: application/json\r\n"))
    #expect(requests[0].contains("Host: localhost\r\n"))
    #expect(requests[0].contains("Origin: snapo://tool\r\n"))
    #expect(requests[1].hasPrefix("POST /items HTTP/1.1\r\n"))
    #expect(requests[1].contains("Content-Length: 16\r\n"))
    #expect(requests[1].hasSuffix(#"{"enabled":true}"#))
    #expect(server.commands == [
      "host:transport:phone", "localabstract:snapo_network_42",
      "host:transport:phone", "localabstract:snapo_network_42"
    ])
    #expect(!server.commands.contains { $0.contains("forward") })
  }

  @Test("EventSource chunks arrive before the response completes")
  func streamsDelayedEvents() async throws {
    let head = Data(
      "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\n\r\n".utf8
    )
    let server = FakeToolADB(plans: [
      .response([
        .init(data: head + Self.chunk("data: first\n\n")),
        .init(delay: 0.15, data: Self.chunk("data: second\n\n")),
        .init(delay: 0.15, data: Data("0\r\n\r\n".utf8))
      ])
    ])
    defer { server.close() }
    let recorder = ChunkRecorder()
    var request = URLRequest(url: Self.endpoint.appending(path: "events"))
    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
    try await Self.operation(request, adb: server.client()).run(
      onResponse: { recorder.receive($0) },
      onData: { recorder.receive($0) }
    )
    let chunks = recorder.chunks
    #expect(chunks.map { String(decoding: $0.data, as: UTF8.self) } == ["data: first\n\n", "data: second\n\n"])
    #expect(chunks[0].time.duration(to: chunks[1].time) >= .milliseconds(100))
    #expect(recorder.response?.headers.first(name: "Content-Type") == "text/event-stream")
  }

  @Test("HTTP framing survives fragmented headers, chunk extensions, and trailers")
  func decodesFragmentedResponse() async throws {
    let bytes = Array(
      ("HTTP/1.1 100 Continue\r\n\r\n"
        + "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n"
        + "5;sample=yes\r\nhello\r\n0\r\nX-Finished: yes\r\n\r\n").utf8
    )
    let server = FakeToolADB(plans: [
      .response(bytes.map { .init(delay: 0.001, data: Data([$0])) })
    ])
    defer { server.close() }
    let (head, body) = try await Self.operation(
      URLRequest(url: Self.endpoint.appending(path: "items")), adb: server.client()
    ).load(maximumBytes: 1024)
    #expect(head.status == .ok)
    #expect(String(decoding: body, as: UTF8.self) == "hello")
  }

  @Test("HTTP responses without Content-Length finish at EOF")
  func decodesEOFResponse() async throws {
    let server = FakeToolADB(plans: [.response([
      .init(data: Data("HTTP/1.1 200 OK\r\nConnection: close\r\n\r\nhello".utf8))
    ])])
    defer { server.close() }
    let (_, body) = try await Self.operation(
      URLRequest(url: Self.endpoint.appending(path: "items")), adb: server.client()
    ).load(maximumBytes: 1024)
    #expect(String(decoding: body, as: UTF8.self) == "hello")
  }

  @Test("Truncated and malformed HTTP framing fails", arguments: [
    "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhi",
    "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\nz\r\n",
    "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nContent-Length: 5\r\n\r\n",
    "HTTP/1.1 200 OK\r\nX-Large: " + String(repeating: "x", count: 17 * 1024) + "\r\n\r\n"
  ])
  func rejectsMalformedResponse(_ response: String) async throws {
    let server = FakeToolADB(plans: [.response([.init(data: Data(response.utf8))])])
    defer { server.close() }
    let operation = try Self.operation(
      URLRequest(url: Self.endpoint.appending(path: "items")), adb: server.client()
    )
    await #expect(throws: (any Error).self) {
      try await operation.load(maximumBytes: 1024)
    }
  }

  @Test("Task cancellation closes a pending HTTP read")
  func cancelsTask() async throws {
    let server = FakeToolADB(plans: [.waitForCancellation])
    defer { server.close() }
    let operation = try Self.operation(URLRequest(url: Self.endpoint.appending(path: "events")), adb: server.client())
    let task = Task { try await operation.load(maximumBytes: 1024) }
    try await eventually { server.requests.count == 1 }
    task.cancel()
    await #expect(throws: (any Error).self) { try await task.value }
    try await eventually { server.cancelledConnections == 1 }
  }

  @Test("Health request timeout closes an unresponsive server connection")
  func timesOut() async throws {
    let server = FakeToolADB(plans: [.waitForCancellation])
    defer { server.close() }
    let adb = server.client()
    let input = try ToolHTTPRequestInput(request: URLRequest(url: Self.endpoint))
    let operation = ToolHTTPRequestOperation(input: input, requestTimeout: .milliseconds(100)) {
      try await adb.openLocalAbstract(deviceID: Self.reference.deviceId, abstractSocket: Self.reference.socketName)
    }
    await #expect(throws: (any Error).self) { try await operation.load(maximumBytes: 1024) }
    try await eventually { server.cancelledConnections == 1 }
  }

  @Test("Cancellation before opening does not contact ADB")
  func cancelsBeforeOpening() async throws {
    let server = FakeToolADB(plans: [])
    defer { server.close() }
    let operation = try Self.operation(URLRequest(url: Self.endpoint), adb: server.client())
    let task = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return try await operation.load(maximumBytes: 1024)
    }
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(server.connectionCount == 0)
  }

  @Test("Cancellation interrupts a stalled ADB handshake", arguments: [0, 1])
  func cancelsStalledHandshake(command: Int) async throws {
    let server = FakeToolADB(plans: [.stallHandshake(command: command)])
    defer { server.close() }
    let operation = try Self.operation(URLRequest(url: Self.endpoint), adb: server.client(timeout: .seconds(10)))
    let task = Task { try await operation.load(maximumBytes: 1024) }
    try await eventually { server.commands.count == command + 1 }
    let start = ContinuousClock.now
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(start.duration(to: .now) < .seconds(1))
    try await eventually { server.cancelledConnections == 1 }
    #expect(server.connectionCount == 1)
    #expect(server.requests.isEmpty)
  }

  @Test("Cancellation after the ADB handshake closes the unclaimed socket")
  func cancelsBeforeSocketTransfer() async throws {
    let server = FakeToolADB(plans: [.waitForCancellation])
    defer { server.close() }
    let adb = server.client()
    let input = try ToolHTTPRequestInput(request: URLRequest(url: Self.endpoint))
    let operation = ToolHTTPRequestOperation(input: input) {
      let connection = try await adb.openLocalAbstract(deviceID: Self.reference.deviceId, abstractSocket: Self.reference.socketName)
      withUnsafeCurrentTask { $0?.cancel() }
      return connection
    }
    let task = Task { try await operation.load(maximumBytes: 1024) }
    await #expect(throws: CancellationError.self) { try await task.value }
    try await eventually { server.cancelledConnections == 1 }
    #expect(server.requests.isEmpty)
  }

  @Test("NIO rejects invalid methods before sending the request")
  func rejectsInvalidRequest() async throws {
    let server = FakeToolADB(plans: [.waitForCancellation])
    defer { server.close() }
    let adb = server.client()
    var request = URLRequest(url: Self.endpoint)
    request.httpMethod = "GET injected"
    let input = try ToolHTTPRequestInput(request: request)
    let operation = ToolHTTPRequestOperation(input: input) {
      try await adb.openLocalAbstract(deviceID: Self.reference.deviceId, abstractSocket: Self.reference.socketName)
    }
    await #expect(throws: HTTPParserError.self) { try await operation.load(maximumBytes: 1024) }
    #expect(server.requests.isEmpty)
  }

  @Test("Body streams are forwarded and collection stays bounded")
  func forwardsBodyStream() async throws {
    let server = FakeToolADB(plans: [.response([.init(data: Self.response(body: "too large"))])])
    defer { server.close() }
    var request = URLRequest(url: Self.endpoint.appending(path: "items"))
    request.httpMethod = "POST"
    request.httpBodyStream = InputStream(data: Data("upload".utf8))
    let operation = try Self.operation(request, adb: server.client())
    await #expect(throws: ToolHTTPTransportError.self) { try await operation.load(maximumBytes: 4) }
    #expect(server.requests.first?.hasSuffix("\r\n\r\nupload") == true)
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
    let server = FakeToolADB(plans: [.response([.init(data: Data(response.utf8))])])
    defer { server.close() }
    let handler = ToolSchemeHandler()
    handler.authorize(ToolHTTPService.Endpoint(id: UUID(), reference: Self.reference, adb: server.client()))
    let task = SchemeTask(URLRequest(url: Self.endpoint.appending(path: "items")))
    handler.webView(WKWebView(), start: task)
    try await eventually { task.finished || task.failure != nil }
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
    let server = FakeToolADB(plans: [.waitForCancellation])
    defer { server.close() }
    let handler = ToolSchemeHandler()
    handler.authorize(ToolHTTPService.Endpoint(id: UUID(), reference: Self.reference, adb: server.client()))
    let task = SchemeTask(URLRequest(url: Self.endpoint.appending(path: "events")))
    let webView = WKWebView()
    handler.webView(webView, start: task)
    try await eventually { server.requests.count == 1 }
    switch action {
    case "disconnect": handler.authorize(nil)
    case "invalidate": handler.invalidate()
    default: handler.webView(webView, stop: task)
    }
    try await eventually { server.cancelledConnections == 1 }
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
    let webView = WKWebView()
    let unknown = try SchemeTask(URLRequest(
      url: #require(URL(string: "snapo://other/api/items"))
    ))
    handler.webView(webView, start: unknown)
    #expect(unknown.failure != nil)
    handler.invalidate()
    let stale = SchemeTask(URLRequest(url: Self.endpoint.appending(path: "items")))
    handler.webView(webView, start: stale)
    #expect(stale.failure != nil)
    #expect(server.connectionCount == 0)
  }

  @Test("WebKit fetch and EventSource use the API path")
  @MainActor
  func webKitUsesSchemeHandler() async throws {
    _ = NSApplication.shared
    let eventHead = Data(
      "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\n\r\n".utf8
    )
    let server = FakeToolADB(plans: [
      .response([.init(data: Self.response(body: #"{"source":"fetch"}"#))]),
      .response([
        .init(data: eventHead + Self.chunk("event: update\ndata: live\n\n")),
        .init(data: Data("0\r\n\r\n".utf8))
      ])
    ])
    defer { server.close() }
    let bridge = ToolWebBridge()
    bridge.hostStateHandler = { ToolConnectionState() }
    bridge.isActiveHandler = { true }
    let container = ToolWebContainer(bridge: bridge, storageIdentifier: nil)
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
      styleMask: [.borderless], backing: .buffered, defer: false
    )
    window.contentView = container.webView
    window.orderBack(nil)
    var ready = false
    container.pageReadinessChangedHandler = { ready = $0 }
    container.setServer(ToolHTTPService.Endpoint(
      id: UUID(), reference: Self.reference, adb: server.client()
    ))
    try container.start(frontend: ToolFrontendBundle(files: ["index.html": Data("<p>Tool</p>".utf8)]))
    let deadline = ContinuousClock.now + .seconds(10)
    while !ready, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    try #require(ready)

    let fetched = try await container.webView.callAsyncJavaScript(
      "return await fetch('/api/items', {mode: 'same-origin'}).then(response => response.text());",
      arguments: [:], in: nil, contentWorld: .page
    ) as? String
    #expect(fetched == #"{"source":"fetch"}"#)
    let event = try await container.webView.callAsyncJavaScript(
      """
      return await new Promise((resolve, reject) => {
        const source = new EventSource('/api/events');
        const timeout = setTimeout(() => { source.close(); reject(new Error('EventSource timed out')); }, 2000);
        source.addEventListener('update', event => { clearTimeout(timeout); source.close(); resolve(event.data); });
        source.onerror = () => { clearTimeout(timeout); source.close(); reject(new Error('EventSource failed')); };
      });
      """,
      arguments: [:], in: nil, contentWorld: .page
    ) as? String
    #expect(event == "live")
    #expect(server.requests.map { $0.components(separatedBy: "\r\n")[0] } == [
      "GET /items HTTP/1.1", "GET /events HTTP/1.1"
    ])

    container.stop()
    await container.finishStopping()
    window.orderOut(nil)
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

  private func eventually(isolation: isolated (any Actor)? = #isolation, _ condition: () -> Bool) async throws {
    for _ in 0 ..< 200 {
      if condition() { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("Condition did not become true")
  }
}

private extension ToolHTTPRequestOperation {
  func load(maximumBytes: Int) async throws -> (HTTPResponseHead, Data) {
    var response: HTTPResponseHead?
    var data = Data()
    try await run(
      onResponse: { response = $0 },
      onData: { chunk in
        guard data.count + chunk.count <= maximumBytes else { throw ToolHTTPTransportError.invalidResponse }
        data.append(chunk)
      }
    )
    guard let response else { throw ToolHTTPTransportError.invalidResponse }
    return (response, data)
  }
}

private final class SchemeTask: NSObject, WKURLSchemeTask, @unchecked Sendable {
  let request: URLRequest
  private let lock = NSLock()
  private var storedFailure: Error?
  private var storedResponse: HTTPURLResponse?
  private var storedBody = Data()
  private var storedFinished = false

  var response: HTTPURLResponse? {
    lock.withLock { storedResponse }
  }

  var body: Data {
    lock.withLock { storedBody }
  }

  var finished: Bool {
    lock.withLock { storedFinished }
  }

  var failure: Error? {
    lock.withLock { storedFailure }
  }

  init(_ request: URLRequest) {
    self.request = request
  }

  func didReceive(_ response: URLResponse) {
    lock.withLock { storedResponse = response as? HTTPURLResponse }
  }

  func didReceive(_ data: Data) {
    lock.withLock { storedBody.append(data) }
  }

  func didFinish() {
    lock.withLock { storedFinished = true }
  }

  func didFailWithError(_ error: any Error) {
    lock.withLock { storedFailure = error }
  }
}

private final class ChunkRecorder: @unchecked Sendable {
  struct Chunk {
    let time: ContinuousClock.Instant
    let data: Data
  }

  private let lock = NSLock()
  private var storedResponse: HTTPResponseHead?
  private var storedChunks: [Chunk] = []

  var response: HTTPResponseHead? {
    lock.withLock { storedResponse }
  }

  var chunks: [Chunk] {
    lock.withLock { storedChunks }
  }

  func receive(_ response: HTTPResponseHead) {
    lock.withLock { storedResponse = response }
  }

  func receive(_ data: Data) {
    lock.withLock { storedChunks.append(Chunk(time: .now, data: data)) }
  }
}

private final class FakeToolADB: @unchecked Sendable {
  struct Part {
    var delay: TimeInterval = 0
    let data: Data
  }

  enum Plan {
    case response([Part])
    case waitForCancellation
    case stallHandshake(command: Int)
  }

  private let lock = NSLock()
  private let workers = DispatchGroup()
  private var plans: [Plan]
  private var peers: [ADBSocketConnection] = []
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
          if case .stallHandshake(command: index) = plan {
            if try peer.readChunk(maxLength: 1) == nil {
              self.lock.withLock { self.storedCancellations += 1 }
            }
            return
          }
          try peer.writeFully(Data("OKAY".utf8))
        }
        let request = try Self.readRequest(from: peer)
        self.lock.withLock { self.storedRequests.append(request) }
        switch plan {
        case .response(let parts):
          for part in parts {
            if part.delay > 0 { Thread.sleep(forTimeInterval: part.delay) }
            try peer.writeFully(part.data)
          }
        case .waitForCancellation:
          if try peer.readChunk(maxLength: 1) == nil {
            self.lock.withLock { self.storedCancellations += 1 }
          }
        case .stallHandshake:
          Issue.record("Expected the handshake to stall")
        }
      } catch {
        if case .waitForCancellation = plan {
          self.lock.withLock { self.storedCancellations += 1 }
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
