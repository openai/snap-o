import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix

enum ToolURL {
  static let scheme = "snapo"
  static let host = "tool"
  static let frontend = url("snapo://tool/")
  static let api = url("snapo://tool/api/")

  static func isAPI(_ url: URL) -> Bool {
    let path = url.path(percentEncoded: true)
    return url.scheme == scheme && url.host == host && url.port == nil && url.user == nil && url.password == nil
      && url.fragment == nil && (path == "/api" || path.hasPrefix("/api/"))
  }

  private static func url(_ literal: String) -> URL {
    guard let url = URL(string: literal) else {
      preconditionFailure("Invalid tool URL: \(literal)")
    }
    return url
  }
}

struct ToolHTTPRequestInput {
  private static let maximumBodyBytes = 2 * 1024 * 1024

  let head: HTTPRequestHead
  let body: Data

  init(request: URLRequest) throws {
    guard let url = request.url, ToolURL.isAPI(url) else {
      throw ToolHTTPTransportError.invalidRequest
    }
    let method = request.httpMethod ?? "GET"
    let body = try Self.body(from: request)
    guard body.count <= Self.maximumBodyBytes else { throw ToolHTTPTransportError.requestBodyTooLarge }

    var headers = HTTPHeaders()
    for (name, value) in request.allHTTPHeaderFields ?? [:] {
      let lowercased = name.lowercased()
      if ["connection", "content-length", "host", "origin", "transfer-encoding"].contains(lowercased) { continue }
      headers.add(name: name, value: value)
    }
    headers.add(name: "Host", value: "localhost")
    headers.add(name: "Origin", value: "snapo://tool")
    headers.add(name: "Connection", value: "close")
    headers.add(name: "Content-Length", value: String(body.count))

    let headerBytes = headers.reduce(0) { $0 + $1.name.utf8.count + $1.value.utf8.count + 4 }
    guard headerBytes <= 16 * 1024 else { throw ToolHTTPTransportError.requestHeadersTooLarge }
    var target = String(url.path(percentEncoded: true).dropFirst("/api".count))
    if target.isEmpty { target = "/" }
    if let query = url.query(percentEncoded: true) { target += "?" + query }
    head = HTTPRequestHead(version: .http1_1, method: HTTPMethod(rawValue: method), uri: target, headers: headers)
    self.body = body
  }

  private static func body(from request: URLRequest) throws -> Data {
    if let body = request.httpBody { return body }
    guard let stream = request.httpBodyStream else { return Data() }
    stream.open()
    defer { stream.close() }
    var result = Data()
    var buffer = [UInt8](repeating: 0, count: 16 * 1024)
    while true {
      let count = stream.read(&buffer, maxLength: buffer.count)
      guard count >= 0 else { throw stream.streamError ?? ToolHTTPTransportError.invalidRequest }
      if count == 0 { break }
      result.append(buffer, count: count)
      guard result.count <= maximumBodyBytes else { throw ToolHTTPTransportError.requestBodyTooLarge }
    }
    return result
  }
}

struct ToolHTTPRequestOperation {
  typealias OpenConnection = @Sendable () async throws -> ADBSocketConnection

  let input: ToolHTTPRequestInput
  var requestTimeout: TimeAmount?
  let openConnection: OpenConnection

  func run(
    isolation: isolated (any Actor)? = #isolation,
    onResponse: (HTTPResponseHead) async throws -> Void,
    onData: (Data) async throws -> Void
  ) async throws {
    try Task.checkCancellation()
    let connection = try await openConnection()
    defer { connection.close() }
    try Task.checkCancellation()
    let descriptor = try connection.takeSocketDescriptor()
    let stream = try await ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
      .withConnectedSocket(descriptor) { channel in
        channel.eventLoop.makeCompletedFuture {
          var limits = NIOHTTPDecoderLimitConfiguration()
          limits.maxHeaderFieldSize = 16 * 1024
          limits.maxHeaderListSize = 64 * 1024
          try channel.pipeline.syncOperations.addHTTPClientHandlers(decoderLimitConfiguration: limits)
          return try NIOAsyncChannel<HTTPClientResponsePart, HTTPClientRequestPart>(wrappingChannelSynchronously: channel)
        }
      }
    let channel = stream.channel
    let timeout = requestTimeout.map { timeout in
      channel.eventLoop.scheduleTask(in: timeout) { channel.close(promise: nil) }
    }
    defer { timeout?.cancel() }

    try await withTaskCancellationHandler {
      try await stream.executeThenClose { inbound, outbound in
        try Task.checkCancellation()
        var request: [HTTPClientRequestPart] = [.head(input.head)]
        if !input.body.isEmpty { request.append(.body(.byteBuffer(ByteBuffer(bytes: input.body)))) }
        request.append(.end(nil))
        try await outbound.write(contentsOf: request)
        for try await part in inbound {
          try Task.checkCancellation()
          switch part {
          case .head(let head):
            guard !(300 ..< 400).contains(head.status.code) else { throw ToolHTTPTransportError.redirectNotAllowed }
            try await onResponse(head)
          case .body(let bytes):
            try await onData(Data(bytes.readableBytesView))
          case .end:
            return
          }
        }
        throw ToolHTTPTransportError.invalidResponse
      }
    } onCancel: {
      channel.close(promise: nil)
    }
  }

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

enum ToolHTTPTransportError: LocalizedError {
  case invalidRequest
  case requestBodyTooLarge
  case requestHeadersTooLarge
  case invalidResponse
  case redirectNotAllowed

  var errorDescription: String? {
    switch self {
    case .invalidRequest: "Invalid tool request."
    case .requestBodyTooLarge: "Tool request body is too large."
    case .requestHeadersTooLarge: "Tool request headers are too large."
    case .invalidResponse: "The tool returned a malformed HTTP response."
    case .redirectNotAllowed: "Tool redirects are not allowed."
    }
  }
}
