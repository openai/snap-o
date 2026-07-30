import Foundation

struct TweakEventStreamDecoder {
  private var lineBytes: [UInt8] = []
  private var eventName: String?
  private var dataLines: [String] = []

  mutating func consume(_ byte: UInt8) -> Data? {
    guard byte == 0x0A else {
      lineBytes.append(byte)
      return nil
    }

    let line = currentLine()
    lineBytes.removeAll(keepingCapacity: true)
    guard let line else { return nil }
    return consume(line)
  }

  private mutating func currentLine() -> String? {
    if lineBytes.last == 0x0D {
      lineBytes.removeLast()
    }
    return String(bytes: lineBytes, encoding: .utf8)
  }

  private mutating func consume(_ line: String) -> Data? {
    if line.isEmpty {
      defer {
        eventName = nil
        dataLines.removeAll(keepingCapacity: true)
      }

      guard eventName == "tweaks", !dataLines.isEmpty else { return nil }
      return Data(dataLines.joined(separator: "\n").utf8)
    }

    if line.hasPrefix("event:") {
      eventName = Self.fieldValue(line, prefixLength: 6)
    } else if line.hasPrefix("data:") {
      dataLines.append(Self.fieldValue(line, prefixLength: 5))
    }
    return nil
  }

  private static func fieldValue(_ line: String, prefixLength: Int) -> String {
    String(line.dropFirst(prefixLength)).trimmingCharacters(in: .whitespaces)
  }
}
