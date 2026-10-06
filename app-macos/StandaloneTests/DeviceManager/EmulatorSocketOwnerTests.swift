import Darwin
import Foundation

private struct SocketPair {
  let client: Int32
  private var server: Int32
  let clientPort: Int
  let serverPort: Int

  init() throws {
    let listener = socket(AF_INET, SOCK_STREAM, 0)
    guard listener >= 0 else { throw socketTestError() }
    defer { close(listener) }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
    let bound = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    guard bound == 0, listen(listener, 1) == 0 else { throw socketTestError() }
    let serverPort = try Self.port(listener)
    let client = socket(AF_INET, SOCK_STREAM, 0)
    guard client >= 0 else { throw socketTestError() }
    address.sin_port = UInt16(serverPort).bigEndian
    let connected = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        connect(client, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    guard connected == 0 else { close(client); throw socketTestError() }
    let server = accept(listener, nil, nil)
    guard server >= 0 else { close(client); throw socketTestError() }
    self.clientPort = try Self.port(client)
    self.serverPort = serverPort
    self.client = client
    self.server = server
  }

  mutating func closeServer() { close(server); server = -1 }

  func closeBoth() { close(client); close(server) }

  private static func port(_ socket: Int32) throws -> Int {
    var address = sockaddr_in()
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let result = withUnsafeMutablePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(socket, $0, &length) }
    }
    guard result == 0 else { throw socketTestError() }
    return Int(UInt16(bigEndian: address.sin_port))
  }
}

private func socketTestError() -> AndroidHostServiceError {
  AndroidHostServiceError(message: "Could not open synthetic loopback sockets")
}

func runSocketOwnerTests() throws {
  var grpc = try SocketPair()
  defer { grpc.closeBoth() }
  let console = try SocketPair()
  defer { console.closeBoth() }
  let native = EmulatorNativeConnection(processID: getpid(), grpcPort: grpc.serverPort, clientPort: grpc.clientPort)
  try EmulatorSocketOwner.verify(console.client, native: native)
  try expectFailure("connection changed") {
    try EmulatorSocketOwner.verify(console.client, native: EmulatorNativeConnection(
      processID: getppid(), grpcPort: grpc.serverPort, clientPort: grpc.clientPort
    ))
  }
  try expectFailure("connection changed") {
    try EmulatorSocketOwner.verify(console.client, native: EmulatorNativeConnection(
      processID: getpid(), grpcPort: grpc.serverPort, clientPort: console.clientPort
    ))
  }
  try expectFailure("connection changed") {
    try EmulatorSocketOwner.verify(-1, native: native)
  }
  var closedConsole = try SocketPair()
  defer { closedConsole.closeBoth() }
  closedConsole.closeServer()
  try expectFailure("connection changed") { try EmulatorSocketOwner.verify(closedConsole.client, native: native) }
  // A listening port is insufficient: the exact established peer must still exist.
  grpc.closeServer()
  try expectFailure("connection changed") { try EmulatorSocketOwner.verify(console.client, native: native) }
  print("Emulator socket owner tests passed")
}
