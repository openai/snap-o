import Foundation
import SnapODeviceClient

enum CLIRecordQueueError: LocalizedError, Equatable {
  case overflow(limit: Int)
  case sessionFailed(String)

  var errorDescription: String? {
    switch self {
    case .overflow(let limit):
      "The network record queue exceeded " + String(limit)
        + " records. Reconnect to obtain a fresh replay."
    case .sessionFailed(let message):
      message
    }
  }
}

actor CLIRecordQueue {
  private let recordLimit: Int
  private var records: [NetworkServerRecord] = []
  private var recordIndex = 0
  private var waiters: [UUID: CheckedContinuation<NetworkServerRecord?, Error>] = [:]
  private var waiterOrder: [UUID] = []
  private var terminalError: CLIRecordQueueError?
  private var isClosed = false

  init(recordLimit: Int = 4096) {
    precondition(recordLimit > 0)
    self.recordLimit = recordLimit
  }

  @discardableResult
  func push(_ record: NetworkServerRecord) -> Bool {
    guard !isClosed else { return false }
    if let id = waiterOrder.first, let continuation = waiters.removeValue(forKey: id) {
      waiterOrder.removeFirst()
      continuation.resume(returning: record)
      return true
    }
    guard records.count - recordIndex < recordLimit else {
      fail(.overflow(limit: recordLimit))
      return false
    }
    records.append(record)
    return true
  }

  func next(timeout: Duration? = nil) async throws -> NetworkServerRecord? {
    if let record = popRecord() { return record }
    if let terminalError { throw terminalError }
    if isClosed { return nil }

    let id = UUID()
    return try await withCheckedThrowingContinuation { continuation in
      waiters[id] = continuation
      waiterOrder.append(id)
      if let timeout {
        Task { [weak self] in
          try? await Task.sleep(for: timeout)
          await self?.timeOut(id)
        }
      }
    }
  }

  func close() {
    guard !isClosed else { return }
    isClosed = true
    for continuation in waiters.values {
      continuation.resume(returning: nil)
    }
    waiters.removeAll()
    waiterOrder.removeAll()
  }

  func closed() -> Bool {
    isClosed
  }

  func fail(_ error: CLIRecordQueueError) {
    guard !isClosed else { return }
    isClosed = true
    terminalError = error
    records.removeAll()
    recordIndex = 0
    for continuation in waiters.values {
      continuation.resume(throwing: error)
    }
    waiters.removeAll()
    waiterOrder.removeAll()
  }

  private func timeOut(_ id: UUID) {
    guard let continuation = waiters.removeValue(forKey: id) else { return }
    waiterOrder.removeAll { $0 == id }
    continuation.resume(returning: nil)
  }

  private func popRecord() -> NetworkServerRecord? {
    guard recordIndex < records.count else { return nil }
    let record = records[recordIndex]
    recordIndex += 1
    if recordIndex >= 256, recordIndex * 2 >= records.count {
      records.removeFirst(recordIndex)
      recordIndex = 0
    }
    return record
  }
}

final class CLISession: @unchecked Sendable {
  private let session: NetworkSession
  private let queue: CLIRecordQueue
  private let readerTask: Task<Void, Never>

  private init(session: NetworkSession) {
    self.session = session
    let queue = CLIRecordQueue()
    self.queue = queue
    readerTask = Task {
      let records = await session.records()
      for await record in records {
        guard !Task.isCancelled else { break }
        guard await queue.push(record) else {
          await session.close()
          return
        }
      }
      if let failure = await session.recordStreamFailure() {
        await queue.fail(.sessionFailed(failure.localizedDescription))
      } else {
        await queue.close()
      }
    }
  }

  static func open(
    _ server: CLIServerReference,
    using adb: ADBClient
  ) async throws -> CLISession {
    let session = try await NetworkSession.connect(to: server, using: adb)
    return CLISession(session: session)
  }

  func startStream() async throws {
    try await session.send(method: SnapONetworkProtocol.Method.startStream)
  }

  func command(
    method: String,
    params: [String: JSONValue]? = nil,
    timeout: Duration? = nil
  ) async throws -> NetworkCDPMessage {
    try await session.command(method: method, params: params, timeout: timeout)
  }

  func nextRecord(timeout: Duration? = nil) async throws -> NetworkServerRecord? {
    try await queue.next(timeout: timeout)
  }

  func isClosed() async -> Bool {
    await queue.closed()
  }

  func close() async {
    readerTask.cancel()
    await session.close()
    await queue.close()
  }
}
