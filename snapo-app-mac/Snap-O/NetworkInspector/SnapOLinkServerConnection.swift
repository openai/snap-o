import Foundation
import Network

final class SnapOLinkServerConnection {
  private let connection: NWConnection
  private let queue: DispatchQueue
  private let onEvent: @Sendable (SnapONetRecord) -> Void
  private let onClose: @Sendable (Error?) -> Void
  private var buffer = Data()
  private var isStopped = false

  init(
    port: UInt16,
    queueLabel: String,
    onEvent: @escaping @Sendable (SnapONetRecord) -> Void,
    onClose: @escaping @Sendable (Error?) -> Void
  ) {
    let host = NWEndpoint.Host.ipv4(IPv4Address("127.0.0.1")!)
    let portValue = NWEndpoint.Port(rawValue: port)!
    queue = DispatchQueue(label: queueLabel)
    connection = NWConnection(host: host, port: portValue, using: .tcp)
    self.onEvent = onEvent
    self.onClose = onClose
  }

  func start() {
    connection.stateUpdateHandler = { [weak self] state in
      guard let self else { return }
      switch state {
      case .failed(let error):
        finish(with: error)
      case .cancelled:
        finish(with: nil)
      default:
        break
      }
    }

    connection.start(queue: queue)
    receive()
  }

  func stop() {
    queue.async { [weak self] in
      guard let self, !self.isStopped else { return }
      isStopped = true
      connection.cancel()
    }
  }

  private func receive() {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
      guard let self else { return }

      if let error {
        finish(with: error)
        return
      }

      if let data, !data.isEmpty {
        handleIncomingData(data)
      }

      if isComplete {
        if !buffer.isEmpty {
          let remaining = buffer
          buffer.removeAll(keepingCapacity: false)
          processLine(remaining)
        }
        finish(with: nil)
        return
      }

      receive()
    }
  }

  private func handleIncomingData(_ data: Data) {
    buffer.append(data)

    while let range = buffer.firstRange(of: Data([0x0A])) { // newline
      let lineData = buffer[..<range.lowerBound]
      buffer.removeSubrange(..<range.upperBound)
      processLine(Data(lineData))
    }
  }

  private func processLine(_ data: Data) {
    let trimmed = data.trimmingTrailingNewlines()
    guard !trimmed.isEmpty else { return }

    do {
      let record = try SnapONetRecordDecoder.decode(from: trimmed)
      onEvent(record)
    } catch {
      let raw = String(data: trimmed, encoding: .utf8) ?? ""
      SnapOLog.network.error("Failed to decode NDJSON record: \(error.localizedDescription, privacy: .public) :: \(raw, privacy: .public)")
    }
  }

  private func finish(with error: Error?) {
    guard !isStopped else { return }
    isStopped = true
    connection.cancel()
    onClose(error)
  }
}

private extension Data {
  func trimmingTrailingNewlines() -> Data {
    var trimmed = self
    while let last = trimmed.last, last == 0x0A || last == 0x0D {
      trimmed.removeLast()
    }
    return trimmed
  }
}

extension SnapOLinkServerConnection: @unchecked Sendable {}
