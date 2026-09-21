import Darwin
import Foundation

/// Emulator console commands use a separate authenticated socket, not the ADB server.
struct EmulatorConsole {
  let home: URL
  var connect: (UInt16) throws -> Int32 = EmulatorConsole.open
  var timeout: Duration = .seconds(2)

  func path(serial: String) throws -> String {
    try withSession(serial: serial) { try $0.command("avd path").trimmingCharacters(in: .whitespacesAndNewlines) }
  }

  func stop(serial: String, expectedPath: String) throws {
    try withSession(serial: serial) { session in
      let path = try session.command("avd path").trimmingCharacters(in: .whitespacesAndNewlines)
      guard URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path == expectedPath else {
        throw EmulatorServiceError(message: "The emulator connection changed. Refresh and try again.")
      }
      // Keep identity verification and shutdown on the same connection; serials can be reused.
      _ = try session.command("kill")
    }
  }

  private func withSession<T>(serial: String, _ body: (Session) throws -> T) throws -> T {
    guard serial.hasPrefix("emulator-"), let port = UInt16(serial.dropFirst(9)), port >= 1024 else {
      throw EmulatorServiceError(message: "Invalid emulator console port.")
    }
    let socket = try connect(port)
    defer { Darwin.close(socket) }
    guard fcntl(socket, F_SETFL, O_NONBLOCK) == 0 else { throw failure() }
    var enabled: Int32 = 1
    guard setsockopt(socket, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
      throw failure()
    }
    let session = Session(socket: socket, deadline: .now.advanced(by: timeout))
    let greeting = try session.response()
    if greeting.contains("Authentication required") {
      let token = try String(contentsOf: home.appendingPathComponent(".emulator_console_auth_token"), encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines)
      guard !token.isEmpty, token.count <= 4096, !token.contains(where: \.isNewline) else {
        throw EmulatorServiceError(message: "The emulator console authentication token is invalid.")
      }
      _ = try session.command("auth " + token)
    }
    return try body(session)
  }

  private static func open(_ port: UInt16) throws -> Int32 {
    let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
    guard socket >= 0 else { throw failure() }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = port.bigEndian
    address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
    guard fcntl(socket, F_SETFL, O_NONBLOCK) == 0 else {
      Darwin.close(socket)
      throw failure()
    }
    let result = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.connect(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    if result != 0 {
      guard errno == EINPROGRESS else {
        Darwin.close(socket)
        throw failure()
      }
      do {
        let session = Session(socket: socket, deadline: .now.advanced(by: .seconds(2)))
        try session.wait(Int16(POLLOUT))
        var error: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(socket, SOL_SOCKET, SO_ERROR, &error, &length) == 0, error == 0 else { throw failure() }
      } catch {
        Darwin.close(socket)
        throw error
      }
    }
    return socket
  }

  private static func failure() -> EmulatorServiceError {
    EmulatorServiceError(message: "Could not communicate with the emulator console.")
  }

  private func failure() -> EmulatorServiceError {
    Self.failure()
  }

  private final class Session {
    let socket: Int32
    let deadline: ContinuousClock.Instant
    var buffer = Data()

    init(socket: Int32, deadline: ContinuousClock.Instant) {
      self.socket = socket
      self.deadline = deadline
    }

    func command(_ command: String) throws -> String {
      let data = Data((command + "\n").utf8)
      try data.withUnsafeBytes { bytes in
        guard let base = bytes.baseAddress else { throw EmulatorConsole.failure() }
        var offset = 0
        while offset < bytes.count {
          try wait(Int16(POLLOUT))
          let count = send(socket, base.advanced(by: offset), bytes.count - offset, 0)
          if count > 0 {
            offset += count
          } else if count < 0, errno == EINTR || errno == EAGAIN {
            continue
          } else {
            throw EmulatorConsole.failure()
          }
        }
      }
      return try response()
    }

    func response() throws -> String {
      var lines: [String] = []
      var size = 0
      while true {
        if let end = buffer.firstIndex(of: 10) {
          guard let text = String(data: buffer[..<end], encoding: .utf8) else { throw EmulatorConsole.failure() }
          let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
          buffer.removeSubrange(...end)
          if line == "OK" { return lines.joined(separator: "\n") }
          // Do not echo console replies: an authentication error could contain the token.
          if line.hasPrefix("KO") { throw EmulatorConsole.failure() }
          lines.append(line)
          continue
        }
        try wait(Int16(POLLIN))
        var bytes = [UInt8](repeating: 0, count: 4096)
        let count = recv(socket, &bytes, bytes.count, 0)
        if count < 0, errno == EINTR || errno == EAGAIN { continue }
        guard count > 0 else { throw EmulatorConsole.failure() }
        size += count
        guard size <= 64 * 1024 else { throw EmulatorConsole.failure() }
        buffer.append(contentsOf: bytes.prefix(count))
      }
    }

    func wait(_ events: Int16) throws {
      while true {
        let remaining = ContinuousClock.now.duration(to: deadline)
        guard remaining > .zero else { throw EmulatorServiceError(message: "The emulator console timed out.") }
        let parts = remaining.components
        let milliseconds = parts.seconds * 1000 + parts.attoseconds / 1_000_000_000_000_000 + 1
        var descriptor = pollfd(fd: socket, events: events, revents: 0)
        let result = poll(&descriptor, 1, Int32(clamping: milliseconds))
        if result > 0 { return }
        if result < 0, errno != EINTR { throw EmulatorConsole.failure() }
      }
    }
  }
}
