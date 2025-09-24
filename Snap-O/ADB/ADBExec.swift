import CoreGraphics
import Darwin
import Foundation

struct ADBForwardHandle: Sendable {
  fileprivate let deviceID: String
  fileprivate let localPort: UInt16
  fileprivate let remote: String

  var port: UInt16 { localPort }
}

struct ADBExec: Sendable {
  typealias PathResolver = @Sendable () async throws -> URL
  typealias ServerObserver = @Sendable () async -> Void

  private let pathResolver: PathResolver
  private let notifyServerAvailable: ServerObserver

  private static let serverLauncher = ADBServerLauncher()

  // MARK: - Public entry points

  init(pathResolver: @escaping PathResolver, serverObserver: @escaping ServerObserver) {
    self.pathResolver = pathResolver
    notifyServerAvailable = serverObserver
  }

  func screencapPNG(deviceID: String) async throws -> Data {
    try await runShellData(deviceID: deviceID, command: "screencap -p 2>/dev/null")
  }

  func startScreenrecord(
    deviceID: String,
    bitRateMbps: Int = 8,
    timeLimitSeconds: Int = 60 * 60 * 3,
    bugReport: Bool = false
  ) async throws -> RecordingSession {
    let sizeHint = try? await displaySize(deviceID: deviceID)
    let remote = "/data/local/tmp/snapo_recording_\(UUID().uuidString).mp4"
    let command = makeScreenRecordCommand(
      bitRateMbps: bitRateMbps,
      timeLimitSeconds: timeLimitSeconds,
      size: sizeHint,
      destination: remote,
      bugReport: bugReport
    )

    let connection = try await makeConnection()
    try connection.sendTransport(to: deviceID)
    try connection.sendShell("sh -c 'echo $$; exec \(command)'")

    guard let pidLine = try connection.readLine(),
          let pidValue = Int32(pidLine.trimmingCharacters(in: .whitespacesAndNewlines))
    else {
      connection.close()
      throw ADBError.parseFailure("Unable to determine screenrecord pid")
    }

    return RecordingSession(
      deviceID: deviceID,
      remotePath: remote,
      pid: pidValue,
      connection: connection,
      startedAt: Date()
    )
  }

  func stopScreenrecord(session: RecordingSession, savingTo localURL: URL) async throws {
    await sendSigInt(deviceID: session.deviceID, pid: session.pid)
    try await session.waitUntilStopped()
    try await pull(deviceID: session.deviceID, remote: session.remotePath, to: localURL)
    _ = try? await runShellString(
      deviceID: session.deviceID,
      command: "rm -f \(session.remotePath)"
    )
    session.close()
  }

  func startScreenStream(deviceID: String, bitRateMbps: Int = 8) async throws -> ScreenStreamSession {
    let sizeHint = try? await displaySize(deviceID: deviceID)
    let command = makeScreenRecordCommand(
      bitRateMbps: bitRateMbps,
      timeLimitSeconds: 0,
      size: sizeHint,
      destination: "-",
      outputFormat: "h264"
    )

    let connection = try await makeConnection()
    try connection.sendTransport(to: deviceID)
    try connection.sendShell(command)

    _ = try? await keyEvent(deviceID: deviceID, keyCode: "KEYCODE_WAKEUP")
    return ScreenStreamSession(
      deviceID: deviceID,
      connection: connection,
      startedAt: Date()
    )
  }

  func displaySize(deviceID: String) async throws -> String {
    let result = try await runShellString(deviceID: deviceID, command: "dumpsys window displays")
    guard let match = result.firstMatch(of: /cur=(?<size>\d+x\d+)/) else {
      throw ADBError.parseFailure("Unable to find window size")
    }
    return String(match.output.size)
  }

  func displayDensity(deviceID: String) async throws -> CGFloat {
    if let wmOutput = try? await runShellString(deviceID: deviceID, command: "wm density"),
       let density = parseDensity(from: wmOutput) {
      return density
    }

    if let prop = try? await runShellString(deviceID: deviceID, command: "getprop ro.sf.lcd_density"),
       let density = parseDensity(from: prop) {
      return density
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

  func getProperties(deviceID: String, prefix: String? = nil) async throws -> [String: String] {
    let output = try await runShellString(deviceID: deviceID, command: "getprop")
    var result: [String: String] = [:]
    for line in output.split(separator: "\n") {
      guard let property = parsePropertyLine(line) else { continue }
      if let prefix {
        if property.key.hasPrefix(prefix) { result[property.key] = property.value }
      } else {
        result[property.key] = property.value
      }
    }
    return result
  }

  func trackDevices() async throws -> (handle: TrackDevicesHandle, stream: AsyncThrowingStream<String, Error>) {
    let connection = try await makeConnection()
    try connection.sendTrackDevices()

    let stream = AsyncThrowingStream<String, Error> { continuation in
      let streamTask = Task.detached(priority: .userInitiated) {
        do {
          while !Task.isCancelled {
            guard let payload = try connection.readLengthPrefixedPayload() else { break }
            guard let payloadString = String(bytes: payload, encoding: .utf8) else { break }
            continuation.yield(payloadString)
          }
          continuation.finish()
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

  func devicesList() async throws -> String {
    try await withConnection { connection in
      try connection.sendDevicesList()
      guard let payload = try connection.readLengthPrefixedPayload() else { return "" }
      return String(data: payload, encoding: .utf8) ?? ""
    }
  }

  func listUnixSockets(deviceID: String) async throws -> String {
    try await runShellString(deviceID: deviceID, command: "cat /proc/net/unix")
  }

  func forwardLocalAbstract(deviceID: String, abstractSocket: String) async throws -> ADBForwardHandle {
    try await withConnection { connection in
      let remote = "localabstract:\(abstractSocket)"
      let portValue = try Self.allocateEphemeralPort()
      _ = try connection.sendHostCommand(
        "host-serial:\(deviceID):forward:tcp:\(portValue);\(remote)",
        expectsResponse: false
      )
      return ADBForwardHandle(
        deviceID: deviceID,
        localPort: portValue,
        remote: remote
      )
    }
  }

  func removeForward(_ handle: ADBForwardHandle) async {
    _ = try? await withConnection { connection in
      try connection.sendHostCommand(
        "host-serial:\(handle.deviceID):killforward:tcp:\(handle.localPort)",
        expectsResponse: false
      )
    }
  }

  // Currently exposed for LivePreviewPointerInjector which issues multiple calls over a single connection.
  // Need a more consistent API.
  func makeConnection(maxAttempts: Int = 3) async throws -> ADBSocketConnection {
    try await runWithRetry(maxAttempts: maxAttempts) { connection in connection }
  }

  // MARK: - Private helpers

  private func runShellData(deviceID: String, command: String) async throws -> Data {
    try await withConnection { connection in
      try connection.sendTransport(to: deviceID)
      try connection.sendShell(command)
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
    try await runWithRetry(maxAttempts: maxAttempts) { connection in
      defer { connection.close() }
      return try body(connection)
    }
  }

  private func runWithRetry<T>(
    maxAttempts: Int,
    _ operation: @escaping @Sendable (ADBSocketConnection) async throws -> T
  ) async throws -> T where T: Sendable {
    var lastError: Error?
    var didRestartServer = false

    for attempt in 0 ..< maxAttempts {
      try await ADBExec.serverLauncher.waitForOngoingRestart()

      do {
        let connection = try ADBSocketConnection()
        do {
          let value = try await operation(connection)
          await notifyServerAvailable()
          return value
        } catch {
          connection.close()
          throw error
        }
      } catch {
        let normalized = normalize(error)
        lastError = normalized

        guard shouldAttemptServerRestart(for: normalized) else { throw normalized }

        if !didRestartServer {
          didRestartServer = try await startServerIfNeeded()
        }

        let backoff = UInt64(min(1_000_000_000, 100_000_000 << attempt))
        try await Task.sleep(nanoseconds: backoff)
      }
    }

    throw lastError ?? ADBError.serverUnavailable("Failed to communicate with adb server")
  }

  private func startServerIfNeeded() async throws -> Bool {
    do {
      let url = try await pathResolver()
      try await ADBExec.serverLauncher.startServer(at: url)
      return true
    } catch ADBError.adbNotFound {
      return false
    }
  }

  private func sendSigInt(deviceID: String, pid: Int32) async {
    let command = "kill -INT \(pid) >/dev/null 2>&1 || true"
    _ = try? await runShellString(deviceID: deviceID, command: command)
  }

  private func makeScreenRecordCommand(
    bitRateMbps: Int,
    timeLimitSeconds: Int,
    size: String?,
    destination: String,
    outputFormat: String? = nil,
    bugReport: Bool = false
  ) -> String {
    var command = "screenrecord --bit-rate \(bitRateMbps * 1_000_000) --time-limit \(timeLimitSeconds)"
    if let outputFormat, !outputFormat.isEmpty { command += " --output-format=\(outputFormat)" }
    if let size, !size.isEmpty { command += " --size \(size)" }
    if bugReport { command += " --bugreport" }
    command += " \(destination)"
    return command
  }

  private func parseDensity(from value: String) -> CGFloat? {
    if let match = value.firstMatch(of: /Physical density:\s*(\d+)/),
       let number = Double(match.1) {
      return CGFloat(number) / 160.0
    }

    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    if let number = Double(trimmed) {
      return CGFloat(number) / 160.0
    }
    return nil
  }

  private func parsePropertyLine(_ line: Substring) -> (key: String, value: String)? {
    guard let keyStart = line.firstIndex(of: "["),
          let keyEnd = line[keyStart...].firstIndex(of: "]"),
          let valueStart = line[keyEnd...].firstIndex(of: "["),
          let valueEnd = line[valueStart...].firstIndex(of: "]")
    else { return nil }

    let keyRange = line.index(after: keyStart) ..< keyEnd
    let valueRange = line.index(after: valueStart) ..< valueEnd

    return (
      key: String(line[keyRange]),
      value: String(line[valueRange])
    )
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

  private static func allocateEphemeralPort() throws -> UInt16 {
    let fd = Darwin.socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
    guard fd >= 0 else {
      let error = errno
      throw POSIXError(POSIXError.Code(rawValue: error) ?? .EIO)
    }
    defer { Darwin.close(fd) }

    var addr = sockaddr_in()
    addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
    addr.sin_port = in_port_t(0).bigEndian

    let bindResult = withUnsafePointer(to: &addr) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { pointer in
        Darwin.bind(fd, pointer, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    guard bindResult == 0 else {
      let error = errno
      throw POSIXError(POSIXError.Code(rawValue: error) ?? .EIO)
    }

    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let nameResult = withUnsafeMutablePointer(to: &addr) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { pointer in
        getsockname(fd, pointer, &length)
      }
    }
    guard nameResult == 0 else {
      let error = errno
      throw POSIXError(POSIXError.Code(rawValue: error) ?? .EIO)
    }

    return UInt16(bigEndian: addr.sin_port)
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
