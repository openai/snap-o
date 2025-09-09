import CoreGraphics
import Foundation

struct ADBExec: Sendable {
  let url: URL

  private static let serverLauncher = ADBServerLauncher()

  // MARK: - Public entry points

  func screencapPNG(deviceID: String) async throws -> Data {
    try await runExecData(deviceID: deviceID, command: "screencap -p 2>/dev/null")
  }

  func startScreenrecord(
    deviceID: String,
    bitRateMbps: Int = 8,
    timeLimitSeconds: Int = 60 * 60 * 3,
    size: String? = nil
  ) async throws -> RecordingSession {
    let sizeArg: String?
    if let provided = size, !provided.isEmpty {
      sizeArg = provided
    } else {
      sizeArg = try? await getCurrentDisplaySize(deviceID: deviceID)
    }

    let remote = "/data/local/tmp/snapo_recording_\(UUID().uuidString).mp4"
    var command = [
      "screenrecord",
      "--bit-rate",
      "\(bitRateMbps * 1_000_000)",
      "--time-limit",
      "\(timeLimitSeconds)"
    ]
    if let sizeArg, !sizeArg.isEmpty { command += ["--size", sizeArg] }
    command.append(remote)

    let connection = try await makePersistentConnection()
    try connection.sendTransport(to: deviceID)
    try connection.sendShell(command.joined(separator: " "))

    return RecordingSession(
      deviceID: deviceID,
      remotePath: remote,
      connection: connection,
      startedAt: Date()
    )
  }

  func stopScreenrecord(session: RecordingSession, deviceID: String, savingTo localURL: URL) async throws {
    session.stop()
    try? await Task.sleep(nanoseconds: 1_000_000_000)
    try await pull(deviceID: session.deviceID, remote: session.remotePath, to: localURL)
    _ = try? await runShellString(
      deviceID: session.deviceID,
      command: "rm -f \(session.remotePath)"
    )
  }

  func startScreenStream(deviceID: String, bitRateMbps: Int = 8, size: String? = nil) async throws -> ScreenStreamSession {
    var components = [
      "screenrecord",
      "--output-format=h264",
      "--bit-rate",
      "\(bitRateMbps * 1_000_000)",
      "--time-limit",
      "0"
    ]
    if let size, !size.isEmpty { components += ["--size", size] }
    components.append("-")

    let connection = try await makePersistentConnection()
    try connection.sendTransport(to: deviceID)
    try connection.sendShell(components.joined(separator: " "))

    _ = try? await keyEvent(deviceID: deviceID, keyCode: "KEYCODE_WAKEUP")
    return ScreenStreamSession(
      deviceID: deviceID,
      connection: connection,
      startedAt: Date()
    )
  }

  func screenDensityScale(deviceID: String) async throws -> CGFloat {
    if let wmOutput = try? await runShellString(deviceID: deviceID, command: "wm density") {
      if let match = wmOutput.firstMatch(of: /Physical density:\s*(\d+)/) {
        if let value = Double(match.1) { return CGFloat(value) / 160.0 }
      }
    }
    if let prop = try? await runShellString(deviceID: deviceID, command: "getprop ro.sf.lcd_density") {
      if let value = Double(prop.trimmingCharacters(in: .whitespacesAndNewlines)) {
        return CGFloat(value) / 160.0
      }
    }
    throw ADBError.parseFailure("Unable to determine device density")
  }

  @discardableResult
  func keyEvent(deviceID: String, keyCode: String) async throws -> String {
    try await runShellString(deviceID: deviceID, command: "input keyevent \(keyCode)")
  }

  func getProp(deviceID: String, key: String) async throws -> String {
    try await runShellString(deviceID: deviceID, command: "getprop \(key)")
  }

  func setShowTouches(deviceID: String, enabled: Bool) async throws {
    _ = try await runShellString(
      deviceID: deviceID,
      command: "settings put system show_touches \(enabled ? "1" : "0")"
    )
  }

  func getShowTouches(deviceID: String) async throws -> Bool {
    let value = try await runShellString(
      deviceID: deviceID,
      command: "settings get system show_touches"
    ).trimmingCharacters(in: .whitespacesAndNewlines)
    return value == "1"
  }

  func runShellCommand(deviceID: String, command: String) async throws -> String {
    try await runShellString(deviceID: deviceID, command: command)
  }

  func pull(deviceID: String, remote: String, to localURL: URL) async throws {
    try FileManager.default.createDirectory(
      at: localURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )

    try await withConnection { connection in
      try connection.sendTransport(to: deviceID)
      try connection.sendSync()
      try connection.sendSyncRequest(id: "RECV", path: remote)

      if FileManager.default.fileExists(atPath: localURL.path) {
        try FileManager.default.removeItem(at: localURL)
      }
      FileManager.default.createFile(atPath: localURL.path, contents: nil)

      guard let handle = FileHandle(forWritingAtPath: localURL.path) else {
        throw ADBError.protocolFailure("unable to open destination file for pull")
      }
      defer { try? handle.close() }

      try connection.readSyncData { chunk in
        try handle.write(contentsOf: chunk)
      }
    }
  }

  func getCurrentDisplaySize(deviceID: String) async throws -> String {
    let result = try await runShellString(deviceID: deviceID, command: "dumpsys window displays")
    guard let match = result.firstMatch(of: /cur=(?<size>\d+x\d+)/) else {
      throw ADBError.parseFailure("Unable to find window size")
    }
    return String(match.output.size)
  }

  func getProperties(deviceID: String, prefix: String? = nil) async throws -> [String: String] {
    let output = try await runShellString(deviceID: deviceID, command: "getprop")
    var result: [String: String] = [:]
    for line in output.split(separator: "\n") {
      guard let keyStart = line.firstIndex(of: "["),
            let keyEnd = line[keyStart...].firstIndex(of: "]"),
            let valStart = line[keyEnd...].firstIndex(of: "["),
            let valEnd = line[valStart...].firstIndex(of: "]")
      else { continue }
      let key = String(line[line.index(after: keyStart) ..< keyEnd])
      let value = String(line[line.index(after: valStart) ..< valEnd])
      if let prefix {
        if key.hasPrefix(prefix) { result[key] = value }
      } else {
        result[key] = value
      }
    }
    return result
  }

  func trackDevices() async throws -> (handle: TrackDevicesHandle, stream: AsyncThrowingStream<String, Error>) {
    let connection = try await makePersistentConnection()
    try connection.sendTrackDevices()

    let stream = AsyncThrowingStream<String, Error> { continuation in
      let streamTask = Task.detached(priority: .userInitiated) {
        defer { continuation.finish() }
        do {
          while !Task.isCancelled {
            guard let payload = try connection.readLengthPrefixedPayload() else { break }
            if let payloadString = String(data: payload, encoding: .utf8) {
              continuation.yield(payloadString)
            }
          }
        } catch is CancellationError {
          // Stream cancelled intentionally; swallow.
        } catch {
          continuation.finish(throwing: error)
        }
      }

      continuation.onTermination = { _ in
        streamTask.cancel()
        connection.close()
      }
    }

    let handle = TrackDevicesHandle {
      connection.close()
    }

    return (handle, stream)
  }

  // MARK: - Private helpers

  private func runShellData(deviceID: String, command: String) async throws -> Data {
    return try await runCommand(deviceID: deviceID, command: command, executor: { connection, command in
      try connection.sendShell(command)
    })
  }

  private func runExecData(deviceID: String, command: String) async throws -> Data {
    return try await runCommand(deviceID: deviceID, command: command) { connection, command in
      try connection.sendExec(command)
    }
  }

  private func runCommand(
    deviceID: String,
    command: String,
    executor: @escaping @Sendable (ADBSocketConnection, String) throws -> Void
  ) async throws -> Data {
    return try await withConnection { connection in
      try connection.sendTransport(to: deviceID)
      try executor(connection, command)
      return try connection.readToEnd()
    }
  }

  private func runShellString(deviceID: String, command: String) async throws -> String {
    let data = try await runShellData(deviceID: deviceID, command: command)
    guard let output = String(data: data, encoding: .utf8) else {
      throw ADBError.parseFailure("non-utf8 output from adb")
    }
    return output
  }

  private func withConnection<T>(
    maxAttempts: Int = 3,
    _ body: @escaping @Sendable (ADBSocketConnection) throws -> T
  ) async throws -> T where T: Sendable {
    var attemptsRemaining = maxAttempts
    var didRestartServer = false

    while true {
      try await ADBExec.serverLauncher.waitForOngoingRestart()
      do {
        return try await Task.detached(priority: .userInitiated) {
          let connection = try ADBSocketConnection()
          defer { connection.close() }
          return try body(connection)
        }.value
      } catch {
        let normalized = normalize(error)
        attemptsRemaining -= 1
        guard attemptsRemaining >= 0 else { throw normalized }

        guard shouldAttemptServerRestart(for: normalized) else { throw normalized }

        if !didRestartServer {
          try await startServerIfNeeded()
          didRestartServer = true
        }

        try await Task.sleep(nanoseconds: 100_000_000)
      }
    }
  }

  private func makePersistentConnection(maxAttempts: Int = 3) async throws -> ADBSocketConnection {
    var attemptsRemaining = maxAttempts
    var didRestartServer = false

    while true {
      try await ADBExec.serverLauncher.waitForOngoingRestart()
      do {
        return try ADBSocketConnection()
      } catch {
        let normalized = normalize(error)
        attemptsRemaining -= 1
        guard attemptsRemaining >= 0 else { throw normalized }

        guard shouldAttemptServerRestart(for: normalized) else { throw normalized }

        if !didRestartServer {
          try await startServerIfNeeded()
          didRestartServer = true
        }

        try await Task.sleep(nanoseconds: 100_000_000)
      }
    }
  }

  private func startServerIfNeeded() async throws {
    try await ADBExec.serverLauncher.startServer(at: url)
  }

  private func shouldAttemptServerRestart(for error: Error) -> Bool {
    if let adbError = error as? ADBError {
      if case .serverUnavailable = adbError { return true }
      return false
    }
    if error is POSIXError { return true }
    if (error as NSError).domain == NSPOSIXErrorDomain { return true }
    return false
  }

  private func normalize(_ error: Error) -> Error {
    if let adbError = error as? ADBError { return adbError }
    if let posix = error as? POSIXError {
      return ADBError.serverUnavailable(posix.localizedDescription)
    }
    if (error as NSError).domain == NSPOSIXErrorDomain {
      return ADBError.serverUnavailable((error as NSError).localizedDescription)
    }
    return error
  }
}

struct TrackDevicesHandle {
  private let cancelClosure: @Sendable () -> Void

  init(_ cancelClosure: @escaping @Sendable () -> Void) {
    self.cancelClosure = cancelClosure
  }

  func cancel() {
    cancelClosure()
  }
}

private actor ADBServerLauncher {
  private var currentTask: Task<Void, Error>?

  func startServer(at url: URL) async throws {
    if let currentTask {
      try await currentTask.value
      return
    }

    guard FileManager.default.fileExists(atPath: url.path) else {
      throw ADBError.adbNotFound
    }

    let launchTask = Task.detached(priority: .userInitiated) {
      let ok = url.startAccessingSecurityScopedResource()
      defer { if ok { url.stopAccessingSecurityScopedResource() } }

      let process = Process()
      process.executableURL = url
      process.arguments = ["start-server"]
      let stderr = Pipe()
      process.standardError = stderr
      process.standardOutput = Pipe()

      try process.run()
      process.waitUntilExit()

      let status = process.terminationStatus
      if status != 0 {
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
        let errString = String(data: errData, encoding: .utf8)
        throw ADBError.nonZeroExit(status, stderr: errString)
      } else {
        // Have to wait just a little bit before the server's actually available?
        try await Task.sleep(nanoseconds: 100_000_000)
      }
    }

    currentTask = launchTask
    do {
      try await launchTask.value
      Perf.step(.captureRequest, "Restarted server")
    } catch {
      currentTask = nil
      throw error
    }
    currentTask = nil
  }

  func waitForOngoingRestart() async throws {
    if let currentTask {
      try await currentTask.value
    }
  }
}
