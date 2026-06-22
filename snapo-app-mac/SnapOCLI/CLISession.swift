import Foundation

actor CLIRecordQueue {
  private var records: [NetworkServerRecord] = []
  private var waiters: [UUID: CheckedContinuation<NetworkServerRecord?, Never>] = [:]
  private var waiterOrder: [UUID] = []
  private var isClosed = false

  func push(_ record: NetworkServerRecord) {
    if let id = waiterOrder.first, let continuation = waiters.removeValue(forKey: id) {
      waiterOrder.removeFirst()
      continuation.resume(returning: record)
      return
    }
    records.append(record)
  }

  func next(timeout: Duration? = nil) async -> NetworkServerRecord? {
    if !records.isEmpty { return records.removeFirst() }
    if isClosed { return nil }

    let id = UUID()
    return await withCheckedContinuation { continuation in
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
    records.removeAll()
    for continuation in waiters.values {
      continuation.resume(returning: nil)
    }
    waiters.removeAll()
    waiterOrder.removeAll()
  }

  func closed() -> Bool {
    isClosed
  }

  private func timeOut(_ id: UUID) {
    guard let continuation = waiters.removeValue(forKey: id) else { return }
    waiterOrder.removeAll { $0 == id }
    continuation.resume(returning: nil)
  }
}

final class CLISession: @unchecked Sendable {
  private let queue: CLIRecordQueue
  private let connection: NetworkInspectorConnection

  private init(connection: NetworkInspectorConnection, queue: CLIRecordQueue) {
    self.connection = connection
    self.queue = queue
  }

  static func open(_ server: CLIServerReference) throws -> CLISession {
    let socket = try ADBSocketConnection()
    do {
      try socket.sendTransport(to: server.deviceID)
      try socket.sendLocalAbstract(server.socketName)

      let handler = CLISessionEventHandler()
      let connection = try NetworkInspectorConnection(
        socket: socket,
        serverKey: server.identifier
      ) { event in
        handler.handle(event)
      }
      return CLISession(connection: connection, queue: handler.queue)
    } catch {
      socket.close()
      throw error
    }
  }

  func startStream() throws {
    try connection.startStream()
  }

  func send(_ message: NetworkCDPMessage) throws {
    try connection.send(message)
  }

  func nextRecord(timeout: Duration? = nil) async -> NetworkServerRecord? {
    await queue.next(timeout: timeout)
  }

  func isClosed() async -> Bool {
    await queue.closed()
  }

  func close() async {
    connection.close()
    await queue.close()
  }
}

private final class CLISessionEventHandler: @unchecked Sendable {
  let queue = CLIRecordQueue()

  func handle(_ event: NetworkInspectorConnectionEvent) {
    Task {
      switch event {
      case .closed:
        await queue.close()
      case .record(_, let record):
        await queue.push(record)
      }
    }
  }
}
