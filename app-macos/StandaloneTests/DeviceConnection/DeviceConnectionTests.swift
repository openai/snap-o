import Darwin
import Foundation

@main
struct DeviceConnectionTests {
  static func main() throws {
    try selectionUsesTransportIdentity()
    try staleTargetCannotOpenAnotherSocket()
    try replacementSurvivesOldCleanup()
    try missingIdentityDoesNotFallBackToSerial()
    try selectionRejectsAnotherDevice()
    print("Device connection tests passed")
  }

  private static func selectionUsesTransportIdentity() throws {
    let target = DeviceTarget(serial: "phone", transportID: "42")
    let pair = try sockets()
    defer { pair.close() }
    try pair.connection.bind(to: target)
    let reply = Data("OKAY".utf8)
    _ = reply.withUnsafeBytes { Darwin.write(pair.peer, $0.baseAddress, $0.count) }
    try pair.connection.sendTransport(to: "phone")
    var buffer = [UInt8](repeating: 0, count: 128)
    let count = Darwin.read(pair.peer, &buffer, buffer.count)
    let request = String(decoding: buffer.prefix(count), as: UTF8.self)
    precondition(request == "0014host:transport-id:42", request)
    target.invalidate()
    do {
      try pair.connection.setIOTimeout(nil)
      preconditionFailure("Invalidation must close an attached socket")
    } catch {}
  }

  private static func staleTargetCannotOpenAnotherSocket() throws {
    let target = DeviceTarget(serial: "phone", transportID: "42")
    target.invalidate()
    let pair = try sockets()
    defer { pair.close() }
    do {
      try pair.connection.bind(to: target)
      preconditionFailure("An invalid target must reject late startup")
    } catch {}
  }

  private static func replacementSurvivesOldCleanup() throws {
    let old = DeviceTarget(serial: "phone", transportID: "42")
    let replacement = DeviceTarget(serial: "phone", transportID: "42")
    precondition(old != replacement)
    old.invalidate()
    old.invalidate()
    precondition(replacement.isValid)
    let transport = try replacement.requireTransport(for: "phone")
    precondition(transport == "42")
    var called = 0
    let handler = try replacement.onInvalidation { called += 1 }
    replacement.removeInvalidationHandler(handler)
    replacement.invalidate()
    precondition(called == 0)
  }

  private static func missingIdentityDoesNotFallBackToSerial() throws {
    for id in [nil, "", "0", "-1", "invalid"] as [String?] {
      let target = DeviceTarget(serial: "phone", transportID: id)
      do {
        _ = try target.requireTransport(for: "phone")
        preconditionFailure("A bound operation must require a valid transport ID")
      } catch {}
    }
  }

  private static func selectionRejectsAnotherDevice() throws {
    let target = DeviceTarget(serial: "phone", transportID: "42")
    do {
      _ = try target.requireTransport(for: "other")
      preconditionFailure("A bound client must not select another serial")
    } catch {}
  }

  private static func sockets() throws -> SocketPair {
    var pair: [Int32] = [0, 0]
    guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else { throw POSIXError(.EIO) }
    return SocketPair(connection: ADBSocketConnection(connectedSocket: pair[0]), peer: pair[1])
  }

  private struct SocketPair {
    let connection: ADBSocketConnection
    let peer: Int32

    func close() {
      connection.close()
      Darwin.close(peer)
    }
  }
}
