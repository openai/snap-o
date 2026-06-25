import Foundation

/// An already-connected transport that supplies decoded records in wire order.
public protocol NetworkSessionTransport: Sendable {
  func records() async -> AsyncThrowingStream<NetworkServerRecord, Error>
  func send(_ message: NetworkCDPMessage) async throws
  func close() async
}

public enum NetworkSessionError: Error, LocalizedError, Sendable, Equatable {
  case closed
  case commandTimedOut(String)
  case transportFailed(String)

  public var errorDescription: String? {
    switch self {
    case .closed:
      "The network session is closed."
    case .commandTimedOut(let method):
      "Timed out waiting for \(method)."
    case .transportFailed(let message):
      "The network transport failed: \(message)"
    }
  }
}

/// Coordinates one network-inspector transport and its request/reply lifecycle.
public actor NetworkSession {
  private static let maximumBufferedRecords = 4096

  private struct PendingCommand {
    let continuation: CheckedContinuation<NetworkCDPMessage, Error>
    let timeoutTask: Task<Void, Never>
    var writeTask: Task<Void, Never>?
  }

  private let transport: any NetworkSessionTransport
  private let defaultCommandTimeout: Duration
  private let recordStream: AsyncStream<NetworkServerRecord>
  private let recordContinuation: AsyncStream<NetworkServerRecord>.Continuation

  private var readerTask: Task<Void, Never>?
  private var writeTail: Task<Void, Error>?
  private var pendingCommands: [Int: PendingCommand] = [:]
  private var nextCommandID = 1
  private var isClosed = false
  private var terminalFailure: NetworkSessionError?

  public init(
    transport: any NetworkSessionTransport,
    defaultCommandTimeout: Duration = .seconds(2)
  ) {
    self.transport = transport
    self.defaultCommandTimeout = defaultCommandTimeout
    (recordStream, recordContinuation) = AsyncStream.makeStream(
      of: NetworkServerRecord.self,
      bufferingPolicy: .bufferingOldest(Self.maximumBufferedRecords)
    )
  }

  public static func connect(
    to reference: NetworkServerReference,
    using adb: ADBClient = ADBClient(),
    defaultCommandTimeout: Duration = .seconds(2)
  ) async throws -> NetworkSession {
    let transport = try await ADBNetworkTransport.open(reference: reference, using: adb)
    return NetworkSession(
      transport: transport,
      defaultCommandTimeout: defaultCommandTimeout
    )
  }

  /// Returns the session's single ordered stream of unsolicited records.
  public func records() -> AsyncStream<NetworkServerRecord> {
    startReaderIfNeeded()
    return recordStream
  }

  public func send(
    method: String,
    params: [String: JSONValue]? = nil
  ) async throws {
    try ensureOpen()
    startReaderIfNeeded()
    try await enqueueWrite(
      NetworkCDPMessage(method: method, params: params)
    )
  }

  public func command(
    method: String,
    params: [String: JSONValue]? = nil,
    timeout: Duration? = nil
  ) async throws -> NetworkCDPMessage {
    try Task.checkCancellation()
    try ensureOpen()
    startReaderIfNeeded()

    let commandID = allocateCommandID()
    let message = NetworkCDPMessage(id: commandID, method: method, params: params)
    let commandTimeout = timeout ?? defaultCommandTimeout

    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        guard !Task.isCancelled else {
          continuation.resume(throwing: CancellationError())
          return
        }
        let timeoutTask = Task { [weak self] in
          do {
            try await Task.sleep(for: commandTimeout)
          } catch {
            return
          }
          await self?.timeoutCommand(commandID, method: method)
        }
        pendingCommands[commandID] = PendingCommand(
          continuation: continuation,
          timeoutTask: timeoutTask,
          writeTask: nil
        )
        let writeTask = Task { [weak self] in
          guard let self else { return }
          await writeCommand(message, commandID: commandID)
        }
        pendingCommands[commandID]?.writeTask = writeTask
      }
    } onCancel: {
      Task { await self.cancelCommand(commandID) }
    }
  }

  public func close() async {
    guard transitionToClosed(with: NetworkSessionError.closed) else { return }
    await transport.close()
  }

  /// Returns the failure that ended the record stream, or `nil` after a normal close.
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
    if case .network(let message) = record,
       message.method == nil,
       let id = message.id,
       let pending = pendingCommands.removeValue(forKey: id) {
      pending.timeoutTask.cancel()
      pending.writeTask?.cancel()
      pending.continuation.resume(returning: message)
      return
    }
    if case .dropped = recordContinuation.yield(record) {
      let error = NetworkSessionError.transportFailed(
        "The network record consumer could not keep up. Reconnect to obtain a fresh replay."
      )
      guard transitionToClosed(with: error, terminalFailure: error) else { return }
      let transport = transport
      Task { await transport.close() }
    }
  }

  private func writeCommand(_ message: NetworkCDPMessage, commandID: Int) async {
    guard pendingCommands[commandID] != nil else { return }
    do {
      try await enqueueWrite(message)
    } catch {
      failCommand(commandID, with: error)
    }
  }

  private func enqueueWrite(_ message: NetworkCDPMessage) async throws {
    try ensureOpen()
    let previousWrite = writeTail
    let transport = transport
    let write = Task {
      if let previousWrite {
        _ = try? await previousWrite.value
      }
      try Task.checkCancellation()
      try await transport.send(message)
    }
    writeTail = write
    try await withTaskCancellationHandler {
      try await write.value
    } onCancel: {
      write.cancel()
    }
  }

  private func timeoutCommand(_ id: Int, method: String) {
    failCommand(id, with: NetworkSessionError.commandTimedOut(method))
  }

  private func cancelCommand(_ id: Int) {
    failCommand(id, with: CancellationError())
  }

  private func failCommand(_ id: Int, with error: any Error) {
    guard let pending = pendingCommands.removeValue(forKey: id) else { return }
    pending.timeoutTask.cancel()
    pending.writeTask?.cancel()
    pending.continuation.resume(throwing: error)
  }

  private func transportDidEnd(error: (any Error)?) async {
    let sessionError = error.map {
      NetworkSessionError.transportFailed($0.localizedDescription)
    } ?? NetworkSessionError.closed
    guard transitionToClosed(
      with: sessionError,
      terminalFailure: error == nil ? nil : sessionError
    ) else { return }
    await transport.close()
  }

  private func transitionToClosed(
    with error: any Error,
    terminalFailure: NetworkSessionError? = nil
  ) -> Bool {
    guard !isClosed else { return false }
    isClosed = true
    self.terminalFailure = terminalFailure
    readerTask?.cancel()
    readerTask = nil
    writeTail?.cancel()
    writeTail = nil

    let pending = Array(pendingCommands.values)
    pendingCommands.removeAll()
    for command in pending {
      command.timeoutTask.cancel()
      command.writeTask?.cancel()
      command.continuation.resume(throwing: error)
    }
    recordContinuation.finish()
    return true
  }

  private func ensureOpen() throws {
    guard !isClosed else { throw NetworkSessionError.closed }
  }

  private func allocateCommandID() -> Int {
    var candidate = nextCommandID
    while pendingCommands[candidate] != nil {
      candidate = candidate == Int.max ? 1 : candidate + 1
    }
    nextCommandID = candidate == Int.max ? 1 : candidate + 1
    return candidate
  }
}
