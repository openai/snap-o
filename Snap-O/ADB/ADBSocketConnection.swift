import Foundation
import Darwin

final class ADBSocketConnection {
  private enum Constants {
    static let host = "127.0.0.1"
    static let port: UInt16 = 5037
    static let bufferSize = 64 * 1024
  }

  private let socketDescriptor: Int32
  private var isClosed = false

  init() throws {
    let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
    guard descriptor >= 0 else {
      throw Self.makeSocketError(errno, context: "socket")
    }

    var noSigPipe: Int32 = 1
    _ = withUnsafePointer(to: &noSigPipe) {
      setsockopt(
        descriptor,
        SOL_SOCKET,
        SO_NOSIGPIPE,
        $0,
        socklen_t(MemoryLayout<Int32>.size)
      )
    }

    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = Constants.port.bigEndian
    address.sin_addr = in_addr(s_addr: inet_addr(Constants.host))

    let result = withUnsafePointer(to: &address) { pointer -> Int32 in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { addrPtr in
        Darwin.connect(descriptor, addrPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }

    if result != 0 {
      let error = Self.makeSocketError(errno, context: "connect")
      Darwin.close(descriptor)
      throw error
    }

    socketDescriptor = descriptor
  }

  deinit {
    close()
  }

  func close() {
    guard !isClosed else { return }
    isClosed = true
    shutdown(socketDescriptor, SHUT_RDWR)
    Darwin.close(socketDescriptor)
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

  func readToEnd() throws -> Data {
    var accumulator = Data()
    var buffer = [UInt8](repeating: 0, count: Constants.bufferSize)

    while true {
      guard let bytesRead = try readOnce(into: &buffer) else { break }
      if bytesRead == 0 { break }
      accumulator.append(buffer, count: bytesRead)
    }

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
    guard let bytesRead = try readOnce(into: &buffer) else { return nil }
    if bytesRead == 0 { return nil }
    return Data(buffer.prefix(bytesRead))
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
        _ = try readExact(4)
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
    try data.withUnsafeBytes { buffer in
      guard let start = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
        throw ADBError.protocolFailure("invalid buffer state")
      }

      var remaining = buffer.count
      var pointer = start

      while remaining > 0 {
        try Task.checkCancellation()
        let written = Darwin.send(socketDescriptor, pointer, remaining, 0)

        if written > 0 {
          pointer = pointer.advanced(by: written)
          remaining -= written
          continue
        }

        if written == 0 {
          throw ADBError.serverUnavailable("socket closed during write")
        }

        let errorCode = errno
        if errorCode == EINTR { continue }
        throw Self.makeSocketError(errorCode, context: "send")
      }
    }
  }

  func readLine() throws -> String? {
    var collected = Data()
    var buffer = [UInt8](repeating: 0, count: 256)

    while true {
      guard let bytesRead = try readOnce(into: &buffer) else {
        return collected.isEmpty ? nil : collected.stringByTrimmingNewlines()
      }

      if bytesRead == 0 {
        return collected.isEmpty ? nil : collected.stringByTrimmingNewlines()
      }

      if let newlineIndex = buffer[..<bytesRead].firstIndex(of: UInt8(ascii: "\n")) {
        collected.append(contentsOf: buffer[..<newlineIndex])
        return collected.stringByTrimmingNewlines()
      }

      collected.append(contentsOf: buffer[..<bytesRead])
    }
  }

  private func readOnce(into buffer: inout [UInt8]) throws -> Int? {
    while true {
      try Task.checkCancellation()
      let result = buffer.withUnsafeMutableBytes { pointer -> Int in
        guard let baseAddress = pointer.baseAddress else { return -1 }
        return Darwin.recv(socketDescriptor, baseAddress, pointer.count, 0)
      }

      if result > 0 { return result }
      if result == 0 { return 0 }

      let errorCode = errno
      if errorCode == EINTR { continue }

      throw Self.makeSocketError(errorCode, context: "recv")
    }
  }

  private func readExact(_ count: Int) throws -> Data {
    var remaining = count
    var buffer = Data()
    buffer.reserveCapacity(count)

    while remaining > 0 {
      var temp = [UInt8](repeating: 0, count: remaining)
      guard let read = try readOnce(into: &temp) else {
        throw ADBError.protocolFailure("unexpected EOF while reading from adb server")
      }

      if read == 0 {
        throw ADBError.protocolFailure("unexpected EOF while reading from adb server")
      }

      buffer.append(contentsOf: temp.prefix(read))
      remaining -= read
    }

    return buffer
  }

  private func readOptionalExact(_ count: Int) throws -> Data? {
    var remaining = count
    var buffer = Data()
    buffer.reserveCapacity(count)

    while remaining > 0 {
      var temp = [UInt8](repeating: 0, count: remaining)
      guard let read = try readOnce(into: &temp) else {
        return buffer.isEmpty ? nil : buffer
      }

      if read == 0 {
        if buffer.isEmpty {
          return nil
        } else {
          throw ADBError.protocolFailure("unexpected EOF while reading from adb server")
        }
      }

      buffer.append(contentsOf: temp.prefix(read))
      remaining -= read
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

  private static func makeSocketError(_ code: Int32, context: String) -> ADBError {
    let message = String(cString: strerror(code))
    return ADBError.serverUnavailable("\(context) failed: \(message)")
  }
}

extension ADBSocketConnection: @unchecked Sendable {}

private extension Data {
  func stringByTrimmingNewlines() -> String? {
    guard let string = String(data: self, encoding: .utf8) else { return nil }
    return string.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
