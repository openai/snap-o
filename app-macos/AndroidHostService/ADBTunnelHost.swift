import Darwin
import Foundation

/// Each XPC client owns a separate registry, including cancelled startup requests.
final class ADBTunnelHost: @unchecked Sendable {
  private let lock = NSLock()
  private var tunnels: [String: SSHADBTunnel] = [:]
  private var cancelled: Set<String> = []
  private var closed = false

  func open(id: String, configuration: SSHConfiguration) throws -> ADBTunnelHandle {
    try configuration.validate()
    let tunnel = SSHADBTunnel()
    try lock.withLock {
      guard !closed, !cancelled.contains(id), tunnels[id] == nil else { throw CancellationError() }
      tunnels[id] = tunnel
    }
    do {
      try tunnel.start(configuration: configuration)
      try lock.withLock {
        guard !closed, !cancelled.contains(id) else { throw CancellationError() }
      }
      return ADBTunnelHandle(id: id)
    } catch {
      close(id: id)
      throw error
    }
  }

  func connect(id: String) throws -> FileHandle {
    let tunnel = try lock.withLock {
      guard !closed, let tunnel = tunnels[id] else { throw CancellationError() }
      return tunnel
    }
    return try tunnel.connect()
  }

  func close(id: String) {
    let tunnel = lock.withLock {
      cancelled.insert(id)
      return tunnels.removeValue(forKey: id)
    }
    tunnel?.close()
  }

  func closeAll() {
    let pending = lock.withLock {
      closed = true
      let pending = Array(tunnels.values)
      tunnels.removeAll()
      return pending
    }
    for tunnel in pending {
      tunnel.close()
    }
  }
}

private final class SSHADBTunnel: @unchecked Sendable {
  private let lock = NSLock()
  private let process = Process()
  private let errors = Pipe()
  private var command: Process?
  private var closed = false
  private var diagnostics = Data()
  private let directory = URL(fileURLWithPath: "/tmp").appending(path: "snapo-ssh-" + UUID().uuidString)
  private var controlPath: String {
    directory.appending(path: "control").path
  }

  func start(configuration: SSHConfiguration) throws {
    try lock.withLock {
      guard !closed else { throw CancellationError() }
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
      process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
      process.arguments = Self.arguments(configuration, controlPath: controlPath)
      process.standardInput = FileHandle.nullDevice
      process.standardOutput = FileHandle.nullDevice
      process.standardError = errors
      errors.fileHandleForReading.readabilityHandler = { [weak self] handle in
        let data = handle.availableData
        self?.lock.withLock {
          self?.diagnostics.append(data)
          if let count = self?.diagnostics.count, count > 8192 { self?.diagnostics.removeFirst(count - 8192) }
        }
      }
      try process.run()
    }
    let deadline = ContinuousClock.now + .seconds(15)
    while !FileManager.default.fileExists(atPath: controlPath) {
      try requireRunning()
      guard ContinuousClock.now < deadline else { throw failure("SSH connection timed out.") }
      Thread.sleep(forTimeInterval: 0.02)
    }
    guard try forward(configuration: configuration) else {
      throw failure("Could not create the ADB forward.")
    }
    try requireRunning()
  }

  private func forward(configuration: SSHConfiguration) throws -> Bool {
    let child = Process()
    let output = Pipe()
    try lock.withLock {
      guard !closed, process.isRunning else { throw CancellationError() }
      child.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
      child.arguments = [
        "-F",
        "/dev/null",
        "-S",
        controlPath,
        "-O",
        "forward",
        "-o",
        "BatchMode=yes",
        "-L",
        "\(socketPath):127.0.0.1:\(configuration.adbPort)",
        configuration.destination
      ]
      child.standardInput = FileHandle.nullDevice
      child.standardOutput = FileHandle.nullDevice
      child.standardError = output
      command = child
      try child.run()
    }
    let deadline = ContinuousClock.now + .seconds(5)
    while child.isRunning {
      try requireRunning()
      guard ContinuousClock.now < deadline else { throw failure("SSH forwarding timed out.") }
      Thread.sleep(forTimeInterval: 0.02)
    }
    child.waitUntilExit()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    lock.withLock {
      command = nil
      diagnostics.append(data.suffix(4096))
    }
    return child.terminationStatus == 0
  }

  private func requireRunning() throws {
    try lock.withLock {
      guard !closed else { throw CancellationError() }
      guard process.isRunning else {
        throw NSError(domain: "SnapO.SSH", code: 2, userInfo: [NSLocalizedDescriptionKey:
            "SSH connection failed. " + (String(data: diagnostics, encoding: .utf8) ?? "")])
      }
    }
  }

  private func failure(_ message: String) -> Error {
    lock.withLock {
      NSError(domain: "SnapO.SSH", code: 3, userInfo: [NSLocalizedDescriptionKey:
          message + " " + (String(data: diagnostics, encoding: .utf8) ?? "")])
    }
  }

  func close() {
    let children: [Process]? = lock.withLock {
      guard !closed else { return nil }
      closed = true
      return [process, command].compactMap(\.self).filter(\.isRunning)
    }
    guard let children else { return }
    for child in children {
      child.terminate()
    }
    let deadline = ContinuousClock.now + .seconds(2)
    while children.contains(where: \.isRunning), ContinuousClock.now < deadline {
      Thread.sleep(forTimeInterval: 0.02)
    }
    for child in children where child.isRunning {
      kill(child.processIdentifier, SIGKILL)
    }
    for child in children {
      child.waitUntilExit()
    }
    errors.fileHandleForReading.readabilityHandler = nil
    try? errors.fileHandleForReading.close()
    try? errors.fileHandleForWriting.close()
    try? FileManager.default.removeItem(at: directory)
  }

  static func arguments(_ configuration: SSHConfiguration, controlPath: String) -> [String] {
    var arguments = ["-N", "-T", "-M", "-S", controlPath]
    for option in [
      "ControlPersist=no",
      "ClearAllForwardings=yes",
      "StreamLocalBindMask=0177",
      "StreamLocalBindUnlink=no",
      "BatchMode=yes",
      "ConnectTimeout=10",
      "ServerAliveInterval=15",
      "ServerAliveCountMax=3",
      "ForkAfterAuthentication=no",
      "PermitLocalCommand=no",
      "ForwardAgent=no",
      "ForwardX11=no"
    ] {
      arguments += ["-o", option]
    }
    if let port = configuration.port { arguments += ["-p", String(port)] }
    arguments.append(configuration.destination)
    return arguments
  }

  private var socketPath: String {
    directory.appending(path: "adb").path
  }

  func connect() throws -> FileHandle {
    try lock.withLock {
      guard !closed, process.isRunning else { throw CancellationError() }
      var address = sockaddr_un()
      address.sun_family = sa_family_t(AF_UNIX)
      address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
      let path = socketPath.utf8CString
      guard path.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw POSIXError(.ENAMETOOLONG) }
      withUnsafeMutableBytes(of: &address.sun_path) { buffer in
        buffer.copyBytes(from: path.map { UInt8(bitPattern: $0) })
      }
      let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
      guard descriptor >= 0 else { throw POSIXError(.ENOBUFS) }
      let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
      do {
        guard fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0,
              fcntl(descriptor, F_SETFL, O_NONBLOCK) == 0 else { throw POSIXError(.EIO) }
        let status = withUnsafePointer(to: &address) { pointer in
          pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
          }
        }
        // A local listener should accept immediately; fail rather than block the helper on backlog pressure.
        guard status == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ECONNREFUSED) }
        guard fcntl(descriptor, F_SETFL, 0) == 0 else { throw POSIXError(.EIO) }
        return handle
      } catch {
        try? handle.close()
        throw error
      }
    }
  }
}
