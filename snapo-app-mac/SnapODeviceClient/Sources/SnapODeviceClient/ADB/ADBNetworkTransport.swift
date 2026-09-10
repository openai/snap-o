import Foundation

/// HTTP and SSE over an ADB-forwarded Android abstract socket.
public actor ADBNetworkTransport: NetworkSessionTransport {
  private static let maximumRecordBytes = 16 * 1024 * 1024
  private let urlSession: URLSession
  private let adb: ADBClient
  private let forward: ADBForwardHandle
  private let appInfo: NetworkAppInfo
  private let baseURL: URL
  private var recordStream: AsyncThrowingStream<NetworkServerRecord, Error>?
  private var recordContinuation: AsyncThrowingStream<NetworkServerRecord, Error>.Continuation?
  private var readerTask: Task<Void, Never>?
  private var eventRequest: URLSessionDataTask?
  private var generation = 0
  private var isClosed = false

  private init(session: URLSession, adb: ADBClient, forward: ADBForwardHandle, appInfo: NetworkAppInfo, baseURL: URL) {
    urlSession = session
    self.adb = adb
    self.forward = forward
    self.appInfo = appInfo
    self.baseURL = baseURL
  }

  public static func open(
    reference: NetworkServerReference,
    using adb: ADBClient = ADBClient()
  ) async throws -> ADBNetworkTransport {
    let forward = try await adb.forwardLocalAbstract(deviceID: reference.deviceId, abstractSocket: reference.socketName)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.connectionProxyDictionary = [:]
    configuration.timeoutIntervalForRequest = 30
    configuration.httpCookieStorage = nil
    configuration.urlCredentialStorage = nil
    let session = URLSession(configuration: configuration, delegate: NetworkHTTPRedirectPolicy(), delegateQueue: nil)
    let baseURL = URL(string: "http://127.0.0.1:\(forward.port)/")!
    do {
      var request = URLRequest(url: baseURL.appending(path: ".snap-o/info"))
      request.timeoutInterval = 5
      let (bytes, response) = try await session.bytes(for: request)
      defer { bytes.task.cancel() }
      try validate(response, contentType: "application/json")
      let data = try await readData(bytes, limit: 1_048_576)
      let appInfo = try JSONDecoder().decode(NetworkAppInfo.self, from: data)
      guard appInfo.protocolVersion == SnapONetworkProtocol.supportedVersion else {
        throw ADBError
          .protocolFailure("Unsupported Network Inspector protocol \(appInfo.protocolVersion); update Snap-O and the Android library")
      }
      return ADBNetworkTransport(
        session: session,
        adb: adb,
        forward: forward,
        appInfo: appInfo,
        baseURL: baseURL
      )
    } catch {
      session.invalidateAndCancel()
      await adb.removeForward(forward)
      throw error
    }
  }

  public func records() -> AsyncThrowingStream<NetworkServerRecord, Error> {
    if let recordStream { return recordStream }
    let pair = AsyncThrowingStream<NetworkServerRecord, Error>.makeStream(bufferingPolicy: .bufferingOldest(4096))
    recordStream = pair.stream
    recordContinuation = pair.continuation
    if isClosed {
      pair.continuation.finish()
    } else {
      pair.continuation.onTermination = { [weak self] _ in Task { await self?.close() } }
      pair.continuation.yield(.appInfo(appInfo))
    }
    return pair.stream
  }

  public func startEvents() async throws {
    guard !isClosed else { throw NetworkSessionError.closed }
    _ = records()
    stopEvents()
    let current = generation
    var request = URLRequest(url: url(path: "network"))
    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
    let (bytes, response) = try await urlSession.bytes(for: request)
    do {
      try Self.validate(response, contentType: "text/event-stream")
      try Task.checkCancellation()
      guard !isClosed, generation == current else { throw CancellationError() }
    } catch {
      bytes.task.cancel()
      throw error
    }
    eventRequest = bytes.task
    readerTask = Task { await readEvents(bytes, generation: current) }
  }

  public func stopEvents() {
    generation += 1
    readerTask?.cancel()
    readerTask = nil
    eventRequest?.cancel()
    eventRequest = nil
  }

  public func requestBody(requestID: String) async throws -> String {
    let data = try await bodyData(requestID: requestID, kind: "request-body")
    struct Body: Decodable { let postData: String }
    return try JSONDecoder().decode(Body.self, from: data).postData
  }

  public func responseBody(requestID: String) async throws -> NetworkResponseBody {
    let data = try await bodyData(requestID: requestID, kind: "response-body")
    return try JSONDecoder().decode(NetworkResponseBody.self, from: data)
  }

  private func bodyData(requestID: String, kind: String) async throws -> Data {
    guard !isClosed else { throw NetworkSessionError.closed }
    let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/%?#"))
    guard let encoded = requestID.addingPercentEncoding(withAllowedCharacters: allowed) else {
      throw ADBError.protocolFailure("Invalid request id")
    }
    var components = URLComponents(url: url(path: "network/requests"), resolvingAgainstBaseURL: false)!
    components.percentEncodedPath += "/\(encoded)/\(kind)"
    var request = URLRequest(url: components.url!)
    request.timeoutInterval = 10
    let (bytes, response) = try await urlSession.bytes(for: request)
    defer { bytes.task.cancel() }
    try Self.validate(response, contentType: "application/json")
    return try await Self.readData(bytes, limit: Self.maximumRecordBytes)
  }

  public func replaySnapshot(_ receive: @Sendable (NetworkServerRecord) async throws -> Void) async throws -> UInt64 {
    guard !isClosed else { throw NetworkSessionError.closed }
    var request = URLRequest(url: url(path: "network"))
    request.setValue("application/x-ndjson", forHTTPHeaderField: "Accept")
    let (bytes, response) = try await urlSession.bytes(for: request)
    defer { bytes.task.cancel() }
    try Self.validate(response, contentType: "application/x-ndjson")
    guard let response = response as? HTTPURLResponse,
          let rawWatermark = response.value(forHTTPHeaderField: "SnapO-Sequence"),
          let watermark = UInt64(rawWatermark) else { throw ADBError.protocolFailure("Invalid history snapshot") }
    var line = Data()
    for try await byte in bytes {
      try Task.checkCancellation()
      if byte == 10 {
        guard let text = String(data: line, encoding: .utf8),
              case .network(let message) = NetworkRecordCodec.decode(text),
              let sequence = message.snapoSequence, sequence <= watermark else {
          throw ADBError.protocolFailure("Invalid history record")
        }
        try await receive(.network(message))
        line.removeAll(keepingCapacity: true)
      } else {
        guard line.count < Self.maximumRecordBytes else { throw ADBError.protocolFailure("History record is too large") }
        line.append(byte)
      }
    }
    guard line.isEmpty else { throw ADBError.protocolFailure("Incomplete history snapshot") }
    return watermark
  }

  private func url(path: String) -> URL {
    baseURL.appending(path: path)
  }

  private static func validate(_ response: URLResponse, contentType: String) throws {
    guard let response = response as? HTTPURLResponse, response.statusCode == 200,
          response.mimeType == contentType else {
      throw ADBError.protocolFailure("Network HTTP request failed; check the app process and Android library version")
    }
  }

  private static func readData(_ bytes: URLSession.AsyncBytes, limit: Int) async throws -> Data {
    var data = Data()
    for try await byte in bytes {
      try Task.checkCancellation()
      guard data.count < limit else { throw ADBError.protocolFailure("Network HTTP response is too large") }
      data.append(byte)
    }
    return data
  }

  private func readEvents(_ bytes: URLSession.AsyncBytes, generation current: Int) async {
    do {
      var decoder = NetworkSSEDecoder()
      for try await byte in bytes {
        try Task.checkCancellation()
        guard current == generation, !isClosed else { return }
        if let message = try decoder.append(byte) {
          if case .dropped = recordContinuation?.yield(.network(message)) {
            throw ADBError.protocolFailure("Network event buffer overflowed; reconnect for a fresh snapshot")
          }
        }
      }
      throw ADBError.protocolFailure("Network event stream ended; reconnect for a fresh snapshot")
    } catch {
      guard current == generation, !isClosed else { return }
      recordContinuation?.finish(throwing: error)
      await close()
    }
  }

  public func close() async {
    guard !isClosed else { return }
    isClosed = true
    stopEvents()
    recordContinuation?.finish()
    recordContinuation = nil
    urlSession.invalidateAndCancel()
    await adb.removeForward(forward)
  }
}

private final class NetworkHTTPRedirectPolicy: NSObject, URLSessionTaskDelegate {
  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest,
    completionHandler: @escaping @Sendable (URLRequest?) -> Void
  ) {
    completionHandler(nil)
  }
}
