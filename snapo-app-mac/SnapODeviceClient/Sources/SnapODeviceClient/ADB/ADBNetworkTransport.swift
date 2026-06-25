import Foundation

/// A network-inspector transport connected through an Android abstract socket.
public final class ADBNetworkTransport: NetworkSessionTransport, @unchecked Sendable {
  private static let maximumRecordBytes = 16 * 1024 * 1024
  private static let maximumBufferedRecords = 4096

  private let socket: ADBSocketConnection
  private let stateLock = NSLock()
  private let writeLock = NSLock()

  private var recordStream: AsyncThrowingStream<NetworkServerRecord, Error>?
  private var recordContinuation: AsyncThrowingStream<NetworkServerRecord, Error>.Continuation?
  private var readerTask: Task<Void, Never>?
  private var isClosed = false

  private init(socket: ADBSocketConnection) throws {
    self.socket = socket
    try socket.writeLine(SnapONetworkProtocol.clientHello)
  }

  public static func open(
    reference: NetworkServerReference,
    using adb: ADBClient = ADBClient()
  ) async throws -> ADBNetworkTransport {
    let socket = try await adb.makeConnection()
    do {
      try socket.sendTransport(to: reference.deviceId)
      try socket.sendLocalAbstract(reference.socketName)
      return try ADBNetworkTransport(socket: socket)
    } catch {
      socket.close()
      throw error
    }
  }

  public func records() async -> AsyncThrowingStream<NetworkServerRecord, Error> {
    makeRecordStream()
  }

  public func send(_ message: NetworkCDPMessage) async throws {
    let line = try NetworkRecordCodec.encode(message)
    try writeLock.withLock {
      guard stateLock.withLock({ !isClosed }) else {
        throw NetworkSessionError.closed
      }
      try socket.writeLine(line)
    }
  }

  public func close() async {
    finish(error: nil, cancelReader: true)
  }

  private func makeRecordStream() -> AsyncThrowingStream<NetworkServerRecord, Error> {
    stateLock.withLock {
      if let recordStream { return recordStream }

      let pair = AsyncThrowingStream<NetworkServerRecord, Error>.makeStream(
        bufferingPolicy: .bufferingOldest(Self.maximumBufferedRecords)
      )
      recordStream = pair.stream
      recordContinuation = pair.continuation

      if isClosed {
        pair.continuation.finish()
      } else {
        pair.continuation.onTermination = { [weak self] _ in
          self?.finish(error: nil, cancelReader: true)
        }
        readerTask = Task.detached(priority: .userInitiated) { [weak self] in
          self?.readLoop()
        }
      }
      return pair.stream
    }
  }

  private func readLoop() {
    do {
      while !Task.isCancelled,
            let line = try socket.readLine(maxLength: Self.maximumRecordBytes) {
        guard !line.isEmpty else { continue }
        yield(NetworkRecordCodec.decode(line))
      }
      finish(error: nil, cancelReader: false)
    } catch is CancellationError {
      finish(error: nil, cancelReader: false)
    } catch {
      finish(error: error, cancelReader: false)
    }
  }

  private func yield(_ record: NetworkServerRecord) {
    let continuation = stateLock.withLock {
      isClosed ? nil : recordContinuation
    }
    guard let continuation else { return }
    if case .dropped = continuation.yield(record) {
      finish(
        error: ADBError.protocolFailure(
          "Network Inspector record buffer overflowed; reconnect to obtain a fresh replay"
        ),
        cancelReader: true
      )
    }
  }

  private func finish(error: (any Error)?, cancelReader: Bool) {
    let state = stateLock.withLock { () -> (
      task: Task<Void, Never>?,
      continuation: AsyncThrowingStream<NetworkServerRecord, Error>.Continuation?
    )? in
      guard !isClosed else { return nil }
      isClosed = true
      let task = readerTask
      readerTask = nil
      let continuation = recordContinuation
      recordContinuation = nil
      return (task, continuation)
    }
    guard let state else { return }

    if cancelReader { state.task?.cancel() }
    socket.close()
    if let error {
      state.continuation?.finish(throwing: error)
    } else {
      state.continuation?.finish()
    }
  }
}
