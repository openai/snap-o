import CoreGraphics
import Foundation

struct ADBExec: Sendable {
  typealias PathResolver = @Sendable () async throws -> URL
  typealias ServerObserver = @Sendable () async -> Void

  private let pathResolver: PathResolver
  private let serverObserver: ServerObserver

  private static let serverLauncher = ADBServerLauncher()
  private enum RetryPolicy {
    static let maxServerWaitNanoseconds: UInt64 = 100_000_000
  }

  // MARK: - Public entry points

  init(pathResolver: @escaping PathResolver, serverObserver: @escaping ServerObserver) {
    self.pathResolver = pathResolver
    self.serverObserver = serverObserver
  }

  func screencapPNG(deviceID: String) async throws -> Data {
    try await runExecData(deviceID: deviceID, command: "screencap -p 2>/dev/null")
  }

  func startScreenrecord(
    deviceID: String,
    bitRateMbps: Int = 8,
    timeLimitSeconds: Int = 60 * 60 * 3,
    size: String? = nil
  ) async throws -> RecordingSession {
    let sizeHint = try await resolvedDisplaySize(deviceID: deviceID, providedSize: size)
    let remote = "/data/local/tmp/snapo_recording_\(UUID().uuidString).mp4"
    let command = makeScreenRecordCommand(
      bitRateMbps: bitRateMbps,
      timeLimitSeconds: timeLimitSeconds,
      size: sizeHint,
      destination: remote
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
    await sendSigIntIfNeeded(deviceID: session.deviceID, pid: session.pid)
    try await session.waitUntilStopped()
    try await pull(deviceID: session.deviceID, remote: session.remotePath, to: localURL)
    _ = try? await runShellString(
      deviceID: session.deviceID,
      command: "rm -f \(session.remotePath)"
    )
    session.close()
  }

  func startScreenStream(deviceID: String, bitRateMbps: Int = 8, size: String? = nil) async throws -> ScreenStreamSession {
    let sizeHint = try await resolvedDisplaySize(deviceID: deviceID, providedSize: size)
    let command = makeScreenStreamCommand(bitRateMbps: bitRateMbps, size: sizeHint)

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

  func screenDensityScale(deviceID: String) async throws -> CGFloat {
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

  // Currently exposed for LivePreviewPointerInjector which issues multiple calls over a single connection.
  // Need a more consistent API.
  func makeConnection(maxAttempts: Int = 3) async throws -> ADBSocketConnection {
    try await runWithRetry(maxAttempts: maxAttempts) { connection in connection }
  }

  // MARK: - Private helpers

  private func runShellData(deviceID: String, command: String) async throws -> Data {
    try await runCommand(deviceID: deviceID, command: command) { connection, command in
      try connection.sendShell(command)
    }
  }

  private func runExecData(deviceID: String, command: String) async throws -> Data {
    try await runCommand(deviceID: deviceID, command: command) { connection, command in
      try connection.sendExec(command)
    }
  }

  private func runCommand(
    deviceID: String,
    command: String,
    executor: @escaping @Sendable (ADBSocketConnection, String) throws -> Void
  ) async throws -> Data {
    try await withConnection { connection in
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

    for _ in 0 ..< maxAttempts {
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

        try await Task.sleep(nanoseconds: RetryPolicy.maxServerWaitNanoseconds)
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

  private func notifyServerAvailable() async {
    await serverObserver()
  }

  private func sendSigIntIfNeeded(deviceID: String, pid: Int32) async {
    let command = "kill -INT \(pid) >/dev/null 2>&1 || true"
    _ = try? await runShellString(deviceID: deviceID, command: command)
  }

  private func resolvedDisplaySize(deviceID: String, providedSize: String?) async throws -> String? {
    guard let provided = providedSize?.trimmingCharacters(in: .whitespacesAndNewlines),
          !provided.isEmpty else {
      return try? await getCurrentDisplaySize(deviceID: deviceID)
    }
    return provided
  }

  private func makeScreenRecordCommand(
    bitRateMbps: Int,
    timeLimitSeconds: Int,
    size: String?,
    destination: String
  ) -> String {
    let arguments = makeScreenRecordArguments(
      bitRateMbps: bitRateMbps,
      timeLimitSeconds: timeLimitSeconds,
      size: size
    ) + [destination]
    return arguments.joined(separator: " ")
  }

  private func makeScreenStreamCommand(bitRateMbps: Int, size: String?) -> String {
    let arguments = makeScreenRecordArguments(
      bitRateMbps: bitRateMbps,
      timeLimitSeconds: 0,
      size: size,
      extraFlags: ["--output-format=h264"]
    ) + ["-"]
    return arguments.joined(separator: " ")
  }

  private func makeScreenRecordArguments(
    bitRateMbps: Int,
    timeLimitSeconds: Int,
    size: String?,
    extraFlags: [String] = []
  ) -> [String] {
    var arguments = ["screenrecord"]
    arguments.append(contentsOf: extraFlags)
    arguments.append(contentsOf: ["--bit-rate", "\(bitRateMbps * 1_000_000)"])
    arguments.append(contentsOf: ["--time-limit", "\(timeLimitSeconds)"])
    if let size, !size.isEmpty { arguments.append(contentsOf: ["--size", size]) }
    return arguments
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
