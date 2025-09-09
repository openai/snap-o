import Foundation

final class ADBSocketConnection {
  private enum Constants {
    static let host = "127.0.0.1"
    static let port: UInt16 = 5037
    static let bufferSize = 64 * 1024
  }

  private let input: InputStream
  private let output: OutputStream
  private var isClosed = false

  init() throws {
    var readStream: Unmanaged<CFReadStream>?
    var writeStream: Unmanaged<CFWriteStream>?

    CFStreamCreatePairWithSocketToHost(
      nil,
      Constants.host as CFString,
      UInt32(Constants.port),
      &readStream,
      &writeStream
    )

    guard let unwrappedInput = readStream?.takeRetainedValue(),
          let unwrappedOutput = writeStream?.takeRetainedValue()
    else {
      throw ADBError.serverUnavailable("unable to create socket streams")
    }

    input = unwrappedInput
    output = unwrappedOutput

    input.open()
    output.open()

    if input.streamStatus == .error || output.streamStatus == .error {
      let message = input.streamError?.localizedDescription
        ?? output.streamError?.localizedDescription
        ?? "unknown socket open error"
      close()
      throw ADBError.serverUnavailable(message)
    }
  }

  deinit {
    close()
  }

  func close() {
    guard !isClosed else { return }
    isClosed = true
    input.close()
    output.close()
  }

    guard let payload = request.data(using: .utf8) else {
      throw ADBError.protocolFailure("unable to encode request")
    }
    guard let headerData = header.data(using: .ascii) else {
      throw ADBError.protocolFailure("unable to encode request header")
    }

  func sendTrackDevices() throws {
    try sendRequest("host:track-devices-l")
  }

  func sendTransport(to deviceID: String) throws {
    try sendRequest("host:transport:\(deviceID)")
  }

  func sendShell(_ command: String) throws {
    try sendRequest("shell:\(command)")
  }

  func sendExec(_ command: String) throws {
    try sendRequest("exec:\(command)")
  }

  func sendSync() throws {
    try sendRequest("sync:")
  }

  private func sendRequest(_ request: String) throws {
    let payload = try Self.utf8Data(request, label: "request")
    let header = String(format: "%04X", payload.count)
    let headerData = try Self.asciiData(header, label: "header")
    try writeFully(headerData)
    try writeFully(payload)
    try expectOkay()
  }

  private func expectOkay() throws {
    let statusData = try readExact(4)
    guard let status = String(data: statusData, encoding: .ascii) else {
      throw ADBError.protocolFailure("unable to decode adb status header")
    }

    if status == "OKAY" { return }
    if status == "FAIL" {
      let errorLength = try readLengthPrefix()
      let payload = try readExact(errorLength)
      let message = String(data: payload, encoding: .utf8) ?? "unknown adb failure"
      throw ADBError.protocolFailure(message)
    }
    throw ADBError.protocolFailure("unexpected adb status: \(status)")
  }

  func readToEnd(command: String) throws -> Data {
    var accumulator = Data()
    var buffer = [UInt8](repeating: 0, count: Constants.bufferSize)

    while true {
      let count = buffer.withUnsafeMutableBytes { pointer in
        guard let baseAddress = pointer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return -1 }
        return input.read(baseAddress, maxLength: pointer.count)
      }

      if count > 0 {
        accumulator.append(buffer, count: count)
      } else if count == 0 {
        break
      } else {
        throw input.streamError ?? ADBError.protocolFailure("socket read failed")
      }
    }

    Perf.step(.appFirstSnapshot, "Return readToEnd \(command)")
    return accumulator
  }

  func drainToEnd() throws {
    var scratch = [UInt8](repeating: 0, count: Constants.bufferSize)
    while true {
      let count = try readOnce(into: &scratch)
      if count == 0 { break }
    }
  }

  func readChunk(maxLength: Int) throws -> Data? {
    var buffer = [UInt8](repeating: 0, count: maxLength)
    let count = buffer.withUnsafeMutableBytes { pointer in
      guard let baseAddress = pointer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return -1 }
      return input.read(baseAddress, maxLength: maxLength)
    }

    if count > 0 {
      return Data(buffer.prefix(count))
    }
    if count == 0 {
      return nil
    }
    throw input.streamError ?? ADBError.protocolFailure("socket read failed")
  }

  func readLengthPrefixedPayload() throws -> Data? {
    guard let header = try readOptionalExact(4) else { return nil }
    guard let headerString = String(data: header, encoding: .ascii),
          let length = Int(headerString, radix: 16) else {
      throw ADBError.protocolFailure("invalid length header")
    }
    if length == 0 { return Data() }
    return try readExact(length)
  }

  func sendSyncRequest(id: String, path: String) throws {
    guard id.count == 4 else { throw ADBError.protocolFailure("invalid sync id") }
    guard let idData = id.data(using: .ascii) else {
      throw ADBError.protocolFailure("unable to encode sync id")
    }
    guard let pathData = path.data(using: .utf8) else {
      throw ADBError.protocolFailure("unable to encode sync path")
    }

    var length = UInt32(pathData.count).littleEndian
    let lengthData = withUnsafeBytes(of: &length) { Data($0) }

    var buffer = Data(capacity: idData.count + lengthData.count + pathData.count + 1)
    buffer.append(idData)
    buffer.append(lengthData)
    buffer.append(pathData)
    if pathData.last != 0 {
      buffer.append(0)
    }

    try writeFully(buffer)
  }

  func readSyncData(callback: (Data) throws -> Void) throws {
    while true {
      let idData = try readExact(4)
      guard let id = String(data: idData, encoding: .ascii) else {
        throw ADBError.protocolFailure("unable to decode sync id")
      }

      switch id {
      case "DATA":
        let expected = try readLittleEndianLength()
        let payload = try readExact(expected)
        try callback(payload)
      case "DONE":
        _ = try readExact(4) // mtime
        return
      case "FAIL":
        let length = try readLittleEndianLength()
        let payload = try readExact(length)
        let message = String(data: payload, encoding: .utf8) ?? "unknown sync failure"
        throw ADBError.protocolFailure(message)
      default:
        throw ADBError.protocolFailure("unexpected sync id: \(id)")
      }
    }
  }

  private func writeFully(_ data: Data) throws {
    try data.withUnsafeBytes { rawBuffer in
      guard let base = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
        throw ADBError.protocolFailure("invalid buffer state")
      }

      var bytesRemaining = rawBuffer.count
      var pointer = base

      while bytesRemaining > 0 {
        try Task.checkCancellation()
        let written = output.write(pointer, maxLength: bytesRemaining)
        if written > 0 {
          bytesRemaining -= written
          pointer = pointer.advanced(by: written)
        } else if written == 0 {
          throw ADBError.protocolFailure("socket closed during write")
        } else {
          throw output.streamError ?? ADBError.protocolFailure("socket write failed")
        }
      }
    }
  }

  private func readExact(_ count: Int) throws -> Data {
    var remaining = count
    var buffer = Data()
    buffer.reserveCapacity(count)

    while remaining > 0 {
      try Task.checkCancellation()
      var temp = [UInt8](repeating: 0, count: remaining)
      let read = temp.withUnsafeMutableBytes { pointer in
        guard let base = pointer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return -1 }
        return input.read(base, maxLength: remaining)
      }

      if read > 0 {
        buffer.append(contentsOf: temp.prefix(read))
        remaining -= read
        continue
      }

      if read == 0 {
        throw ADBError.protocolFailure("unexpected EOF while reading from adb server")
      }

      throw input.streamError ?? ADBError.protocolFailure("socket read failed")
    }

    return buffer
  }

  private func readLengthPrefix() throws -> Int {
    let header = try readExact(4)
    guard let headerString = String(data: header, encoding: .ascii),
          let length = Int(headerString, radix: 16)
    else {
      throw ADBError.protocolFailure("invalid length header")
    }
    return length
  }

  private func readLittleEndianLength() throws -> Int {
    let data = try readExact(4)
    var value: UInt32 = 0
    withUnsafeMutableBytes(of: &value) { buffer in
      buffer.copyBytes(from: data.prefix(buffer.count))
    }
    return Int(UInt32(littleEndian: value))
  }

  private func readOptionalExact(_ count: Int) throws -> Data? {
    var remaining = count
    var buffer = Data()
    buffer.reserveCapacity(count)

    while remaining > 0 {
      try Task.checkCancellation()
      var temp = [UInt8](repeating: 0, count: remaining)
      let read = temp.withUnsafeMutableBytes { pointer in
        guard let base = pointer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return -1 }
        return input.read(base, maxLength: remaining)
      }

      if read > 0 {
        buffer.append(contentsOf: temp.prefix(read))
        remaining -= read
        continue
      }

      if read == 0 {
        if buffer.isEmpty {
          return nil
        } else {
          throw ADBError.protocolFailure("unexpected EOF while reading from adb server")
        }
      }

      throw input.streamError ?? ADBError.protocolFailure("socket read failed")
    }

    return buffer
  }
}

extension ADBSocketConnection: @unchecked Sendable {}
