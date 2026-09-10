import Foundation

/// HTTP reads and a separately controlled stream of live network events.
public protocol NetworkSessionTransport: Sendable {
  func records() async -> AsyncThrowingStream<NetworkServerRecord, Error>
  func startEvents() async throws
  func stopEvents() async
  func requestBody(requestID: String) async throws -> String
  func responseBody(requestID: String) async throws -> NetworkResponseBody
  func replaySnapshot(_ receive: @Sendable (NetworkServerRecord) async throws -> Void) async throws -> UInt64
  func close() async
}

public enum NetworkSessionError: Error, LocalizedError, Sendable, Equatable {
  case closed
  case transportFailed(String)

  public var errorDescription: String? {
    switch self {
    case .closed: "The network session is closed."
    case .transportFailed(let message): "The network transport failed: \(message)"
    }
  }
}

/// Joins a finite HTTP snapshot with live SSE records from the same app process.
public actor NetworkSession {
  private static let maximumBufferedRecords = 4096
  private let transport: any NetworkSessionTransport
  private let recordStream: AsyncStream<NetworkServerRecord>
  private let recordContinuation: AsyncStream<NetworkServerRecord>.Continuation
  private var readerTask: Task<Void, Never>?
  private var startTask: Task<Void, Error>?
  private var isClosed = false
  private var replayBuffer: [NetworkServerRecord]?
  private var streamGeneration = 0
  private var streamEnabled = false
  private var replayWatermark: UInt64?
  private var terminalFailure: NetworkSessionError?

  public init(transport: any NetworkSessionTransport) {
    self.transport = transport
    (recordStream, recordContinuation) = AsyncStream.makeStream(
      of: NetworkServerRecord.self,
      bufferingPolicy: .bufferingOldest(Self.maximumBufferedRecords)
    )
  }

  public static func connect(
    to reference: NetworkServerReference,
    using adb: ADBClient = ADBClient()
  ) async throws -> NetworkSession {
    let transport = try await ADBNetworkTransport.open(reference: reference, using: adb)
    return NetworkSession(transport: transport)
  }

  public func records() -> AsyncStream<NetworkServerRecord> {
    startReaderIfNeeded()
    return recordStream
  }

  public func requestBody(requestID: String) async throws -> String {
    try ensureOpen()
    let body = try await transport.requestBody(requestID: requestID)
    try ensureOpen()
    return body
  }

  public func responseBody(requestID: String) async throws -> NetworkResponseBody {
    try ensureOpen()
    let body = try await transport.responseBody(requestID: requestID)
    try ensureOpen()
    return body
  }

  public func startStream() async throws {
    try ensureOpen()
    if streamEnabled { return }
    if let startTask { return try await startTask.value }
    streamGeneration += 1
    let generation = streamGeneration
    let task = Task { try await beginStream(generation: generation) }
    startTask = task
    do {
      try await withTaskCancellationHandler {
        try await task.value
      } onCancel: {
        task.cancel()
      }
      if generation == streamGeneration { startTask = nil }
    } catch {
      if generation == streamGeneration { startTask = nil }
      throw error
    }
  }

  private func beginStream(generation: Int) async throws {
    replayBuffer = []
    replayWatermark = nil
    startReaderIfNeeded()
    do {
      try await transport.startEvents()
      try Task.checkCancellation()
      let watermark = try await transport.replaySnapshot { record in
        try await self.receiveSnapshot(record, generation: generation)
      }
      try ensureOpen()
      guard generation == streamGeneration else { throw CancellationError() }
      let buffered = replayBuffer ?? []
      replayBuffer = nil
      replayWatermark = watermark
      streamEnabled = true
      publish(.replayComplete(watermark: watermark))
      for record in buffered {
        receive(record)
      }
    } catch {
      if generation == streamGeneration {
        replayBuffer = nil
        streamEnabled = false
        await transport.stopEvents()
      }
      throw error
    }
  }

  public func stopStream() async {
    streamGeneration += 1
    startTask?.cancel()
    startTask = nil
    replayBuffer = nil
    replayWatermark = nil
    streamEnabled = false
    await transport.stopEvents()
  }

  private func receiveSnapshot(_ record: NetworkServerRecord, generation: Int) throws {
    try ensureOpen()
    guard generation == streamGeneration else { throw CancellationError() }
    publish(record)
  }

  public func close() async {
    guard transitionToClosed() else { return }
    await transport.close()
  }

  public func recordStreamFailure() -> NetworkSessionError? {
    terminalFailure
  }

  private func startReaderIfNeeded() {
    guard !isClosed, readerTask == nil else { return }
    let transport = transport
    readerTask = Task { [weak self] in
      do {
        let records = await transport.records()
        for try await record in records {
          guard !Task.isCancelled else { return }
          await self?.receive(record)
        }
        await self?.transportDidEnd(error: nil)
      } catch is CancellationError {
        await self?.transportDidEnd(error: nil)
      } catch {
        await self?.transportDidEnd(error: error)
      }
    }
  }

  private func receive(_ record: NetworkServerRecord) {
    guard !isClosed else { return }
    if case .network(let message) = record, let sequence = message.snapoSequence {
      if replayBuffer != nil {
        guard replayBuffer!.count < Self.maximumBufferedRecords else {
          failRecordBuffer()
          return
        }
        replayBuffer?.append(record)
        return
      }
      guard streamEnabled else { return }
      if let replayWatermark, sequence <= replayWatermark { return }
    }
    publish(record)
  }

  private func publish(_ record: NetworkServerRecord) {
    guard !isClosed else { return }
    if case .dropped = recordContinuation.yield(record) { failRecordBuffer() }
  }

  private func failRecordBuffer() {
    let error = NetworkSessionError.transportFailed(
      "The network record consumer could not keep up. Reconnect to obtain a fresh snapshot."
    )
    guard transitionToClosed(terminalFailure: error) else { return }
    let transport = transport
    Task { await transport.close() }
  }

  private func transportDidEnd(error: (any Error)?) async {
    let failure = error.map { NetworkSessionError.transportFailed($0.localizedDescription) }
    guard transitionToClosed(terminalFailure: failure) else { return }
    await transport.close()
  }

  private func transitionToClosed(terminalFailure: NetworkSessionError? = nil) -> Bool {
    guard !isClosed else { return false }
    isClosed = true
    streamGeneration += 1
    streamEnabled = false
    replayBuffer = nil
    self.terminalFailure = terminalFailure
    startTask?.cancel()
    startTask = nil
    readerTask?.cancel()
    readerTask = nil
    recordContinuation.finish()
    return true
  }

  private func ensureOpen() throws {
    try Task.checkCancellation()
    guard !isClosed else { throw NetworkSessionError.closed }
  }
}
