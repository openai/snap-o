import Foundation

/// Parses complete SSE events without treating partial lines or EOF as messages.
struct NetworkSSEDecoder {
  private var line = Data()
  private var data = Data()
  private var eventID: UInt64?
  private let maximumBytes = 16 * 1024 * 1024

  mutating func append(_ byte: UInt8) throws -> NetworkCDPMessage? {
    guard byte == 10 else {
      guard line.count < maximumBytes + 128 else { throw ADBError.protocolFailure("SSE event is too large") }
      line.append(byte)
      return nil
    }
    if line.last == 13 { line.removeLast() }
    defer { line.removeAll(keepingCapacity: true) }
    guard let text = String(data: line, encoding: .utf8) else { throw ADBError.protocolFailure("SSE contains invalid UTF-8") }
    if text.isEmpty {
      defer { data.removeAll(keepingCapacity: true)
        eventID = nil
      }
      guard !data.isEmpty else { return nil }
      data.removeLast()
      guard let text = String(data: data, encoding: .utf8),
            case .network(let message) = NetworkRecordCodec.decode(text),
            let sequence = message.snapoSequence,
            eventID == nil || eventID == sequence else { throw ADBError.protocolFailure("Invalid network SSE event") }
      return message
    }
    let parts = text.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
    let value = parts.count > 1 ? String(parts[1].first == " " ? parts[1].dropFirst() : parts[1]) : ""
    switch parts[0] {
    case "data":
      guard data.count + value.utf8.count <= maximumBytes else { throw ADBError.protocolFailure("SSE event is too large") }
      data.append(contentsOf: value.utf8)
      data.append(10)
    case "id":
      guard let sequence = UInt64(value) else { throw ADBError.protocolFailure("Invalid SSE sequence") }
      eventID = sequence
    default: break
    }
    return nil
  }
}
