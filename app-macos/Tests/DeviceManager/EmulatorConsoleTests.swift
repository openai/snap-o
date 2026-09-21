import Darwin
import Foundation

private final class ConsoleFixture: @unchecked Sendable {
  let client: Int32
  let peer: Int32
  let finished = DispatchGroup()
  let byteDelay: TimeInterval
  private var commands: [String] = []

  init(greeting: String, byteDelay: TimeInterval = 0, respond: @escaping @Sendable (String) -> String) throws {
    var sockets: [Int32] = [0, 0]
    guard socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets) == 0 else {
      throw EmulatorServiceError(message: "socketpair failed")
    }
    self.byteDelay = byteDelay
    client = sockets[0]
    peer = sockets[1]
    var enabled: Int32 = 1
    setsockopt(peer, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
    finished.enter()
    DispatchQueue.global().async { [self] in
      defer { Darwin.close(peer)
        finished.leave()
      }
      send(greeting)
      var line = ""
      var byte: UInt8 = 0
      while recv(peer, &byte, 1, 0) == 1 {
        if byte == 10 {
          commands.append(line)
          send(respond(line))
          line = ""
        } else { line.append(Character(UnicodeScalar(byte))) }
      }
    }
  }

  private func send(_ text: String) {
    for byte in text.utf8 {
      var byte = byte
      if Darwin.send(peer, &byte, 1, 0) != 1 { return }
      if byteDelay > 0 { Thread.sleep(forTimeInterval: byteDelay) }
    }
  }

  func recorded() -> [String] {
    finished.wait()
    return commands
  }
}

func runConsoleTests() throws {
  try authenticatesBeforeShutdown()
  try refusesToStopAnotherAVD()
  try limitsResponseTime()
}

private func authenticatesBeforeShutdown() throws {
  let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: home) }
  try "test-token".write(to: home.appendingPathComponent(".emulator_console_auth_token"), atomically: true, encoding: .utf8)
  let server = try ConsoleFixture(greeting: "Authentication required\r\nOK\r\n") { command in
    command == "avd path" ? "/Test.avd\r\nOK\r\n" : "OK\r\n"
  }
  try EmulatorConsole(home: home) { _ in server.client }.stop(serial: "emulator-5554", expectedPath: "/Test.avd")
  try expect(server.recorded() == ["auth test-token", "avd path", "kill"], "Shutdown must authenticate first")
}

private func refusesToStopAnotherAVD() throws {
  let server = try ConsoleFixture(greeting: "OK\r\n") { _ in "/other.avd\r\nOK\r\n" }
  try? EmulatorConsole(home: FileManager.default.temporaryDirectory) { _ in server.client }
    .stop(serial: "emulator-5554", expectedPath: "/Test.avd")
  try expect(server.recorded() == ["avd path"], "Never send kill after a serial is reused")
}

private func limitsResponseTime() throws {
  let server = try ConsoleFixture(greeting: String(repeating: "x", count: 100), byteDelay: 0.003) { _ in "" }
  defer { _ = server.recorded() }
  try expectFailure("timed out") {
    _ = try EmulatorConsole(home: FileManager.default.temporaryDirectory, connect: { _ in server.client }, timeout: .milliseconds(40))
      .path(serial: "emulator-5554")
  }
}
