import Foundation

enum NetworkInspectorConnectionEvent {
  case closed(serverKey: String, message: String?)
  case record(serverKey: String, record: NetworkServerRecord)
}

extension NetworkInspectorConnectionEvent: Sendable {}

final class NetworkInspectorConnection: @unchecked Sendable {
  private static let maximumRecordBytes = 16 * 1024 * 1024

  private let serverKey: String
  private let socket: ADBSocketConnection
  private let writeLock = NSLock()
  private let stateLock = NSLock()
  private var readTask: Task<Void, Never>?

  init(
    socket: ADBSocketConnection,
    serverKey: String,
    eventHandler: @escaping @Sendable (NetworkInspectorConnectionEvent) -> Void
  ) throws {
    self.socket = socket
    self.serverKey = serverKey
    try socket.writeLine("HelloSnapO")
    readTask = Task.detached(priority: .userInitiated) { [weak self] in
      self?.readLoop(eventHandler: eventHandler)
    }
  }

  func send(_ message: NetworkCDPMessage) throws {
    let data = try JSONEncoder().encode(message)
    guard let line = String(data: data, encoding: .utf8) else {
      throw ADBError.protocolFailure("unable to encode Network Inspector command")
    }
    try writeLock.withLock {
      try socket.writeLine(line)
    }
  }

  func startStream() throws {
    try send(NetworkCDPMessage(method: "SnapO.startStream"))
  }

  func stopStream() throws {
    try send(NetworkCDPMessage(method: "SnapO.stopStream"))
  }

  func close() {
    let task = stateLock.withLock { () -> Task<Void, Never>? in
      let task = readTask
      readTask = nil
      return task
    }
    task?.cancel()
    socket.close()
  }

  private func readLoop(
    eventHandler: @escaping @Sendable (NetworkInspectorConnectionEvent) -> Void
  ) {
    do {
      while !Task.isCancelled,
            let line = try socket.readLine(maxLength: Self.maximumRecordBytes) {
        guard !line.isEmpty else { continue }
        eventHandler(.record(serverKey: serverKey, record: Self.decode(line: line)))
      }
      eventHandler(.closed(serverKey: serverKey, message: nil))
    } catch is CancellationError {
      eventHandler(.closed(serverKey: serverKey, message: nil))
    } catch {
      eventHandler(.closed(serverKey: serverKey, message: error.localizedDescription))
    }
  }

  private static func decode(line: String) -> NetworkServerRecord {
    guard let data = line.data(using: .utf8),
          let message = try? JSONDecoder().decode(NetworkCDPMessage.self, from: data)
    else {
      return .unknown
    }

    switch message.method {
    case "SnapO.appInfo":
      guard let params = message.params,
            let paramsData = try? JSONEncoder().encode(JSONValue.object(params)),
            let info = try? JSONDecoder().decode(NetworkAppInfo.self, from: paramsData)
      else {
        return .unknown
      }
      return .appInfo(info)
    case "SnapO.replayComplete":
      return .replayComplete
    case .some:
      return .network(message)
    case .none where message.id != nil:
      return .network(message)
    case .none:
      return .unknown
    }
  }
}
