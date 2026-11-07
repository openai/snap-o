import Foundation

/// Reads binary stdout independently of shell diagnostics and exit status.
struct ADBShellV2Stream {
  private static let maximumPayload = 1024 * 1024
  private var output = Data()
  private var offset = 0

  static func standardInput(_ bytes: Data) throws -> Data {
    guard bytes.count <= maximumPayload else { throw ADBError.protocolFailure("ADB shell input is too large") }
    var packet = Data([0])
    withUnsafeBytes(of: UInt32(bytes.count).littleEndian) { packet.append(contentsOf: $0) }
    packet.append(bytes)
    return packet
  }

  mutating func readExactly(_ count: Int, read: (Int) throws -> Data?) throws -> Data {
    var result = Data()
    while result.count < count {
      if offset < output.count {
        let end = min(output.count, offset + count - result.count)
        result.append(output[offset ..< end])
        offset = end
        continue
      }
      let header = try Self.readRaw(5, read: read)
      let length = header.dropFirst().enumerated().reduce(0) { $0 | Int($1.element) << ($1.offset * 8) }
      guard length <= Self.maximumPayload, [1, 2, 3].contains(header[0]),
            header[0] != 3 || length == 1 else {
        throw ADBError.protocolFailure("Invalid ADB shell packet")
      }
      let payload = try Self.readRaw(length, read: read)
      switch header[0] {
      case 1:
        output = payload
        offset = 0
      case 3:
        throw ADBError.protocolFailure("ADB shell exited (status \(payload[0]))")
      default:
        // The helper reports structured failures on stdout. Do not expose framework diagnostics.
        continue
      }
    }
    return result
  }

  private static func readRaw(_ count: Int, read: (Int) throws -> Data?) throws -> Data {
    var bytes = Data()
    while bytes.count < count {
      guard let chunk = try read(count - bytes.count), !chunk.isEmpty else {
        throw ADBError.protocolFailure("ADB shell disconnected")
      }
      bytes.append(chunk)
    }
    return bytes
  }
}
