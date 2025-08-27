import Foundation

private let log = SnapOLog.adb

actor ADBClient {
  private var adbURL: URL?
  private var configurationWaiters: [CheckedContinuation<Void, Never>] = []

  init(adbURL: URL?) {
    self.adbURL = adbURL
  }

  // MARK: Public API

  func setURL(_ newURL: URL?) {
    adbURL = newURL
    guard let url = newURL, FileManager.default.fileExists(atPath: url.path) else { return }
    let waiters = configurationWaiters
    configurationWaiters.removeAll()
    for waiter in waiters {
      waiter.resume()
    }
  }

  func currentURL() -> URL? { adbURL }

  /// Suspends until `adbURL` is set (and exists on disk).
  func awaitConfigured() async {
    if let url = adbURL, FileManager.default.fileExists(atPath: url.path) { return }
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      configurationWaiters.append(continuation)
    }
  }

  func screencapPNG(deviceID: String) async throws -> Data {
    try runData(["-s", deviceID, "exec-out", "sh", "-c", "screencap -p 2>/dev/null"])
  }

  func startScreenrecord(
    deviceID: String,
    bitRateMbps: Int = 8,
    timeLimitSeconds: Int = 60 * 60 * 3,
    size: String? = nil
  ) async throws -> RecordingSession {
    let remote = "/data/local/tmp/snapo_recording.mp4"
    var args = [
      "-s",
      deviceID,
      "shell",
      "screenrecord",
      "--bit-rate",
      "\(bitRateMbps * 1000000)",
      "--time-limit",
      "\(timeLimitSeconds)"
    ]
    if let size, !size.isEmpty {
      args += ["--size", size]
    }
    args += [remote]

    let (process, _, stderr) = try startADBProcess(args)

    return RecordingSession(
      deviceID: deviceID,
      remotePath: remote,
      process: process,
      stderrPipe: stderr,
      startedAt: Date()
    )
  }

  func stopScreenrecord(session: RecordingSession, savingTo localURL: URL) async throws {
    session.process.terminate()
    session.process.waitUntilExit()

    let status = session.process.terminationStatus
    if status != 0, status != 15 {
      let data = try? session.stderrPipe.fileHandleForReading.readToEnd() ?? Data()
      let err = data.flatMap { String(data: $0, encoding: .utf8) }
      throw ADBError.nonZeroExit(session.process.terminationStatus, stderr: err)
    }

    // Give device time to flush the file before pulling
    try await Task.sleep(nanoseconds: 1000000000)

    try pull(deviceID: session.deviceID, remote: session.remotePath, to: localURL)
    _ = try? runString(["-s", session.deviceID, "shell", "rm", "-f", session.remotePath])
  }

  func startScreenStream(
    deviceID: String,
    bitRateMbps: Int = 8,
    size: String? = nil
  ) async throws -> ScreenStreamSession {
    var args = [
      "-s",
      deviceID,
      "exec-out",
      "screenrecord",
      "--output-format=h264",
      "--bit-rate",
      "\(bitRateMbps * 1_000_000)"
    ]
    if let size, !size.isEmpty {
      args += ["--size", size]
    }
    args += ["-"]

    let (process, stdout, stderr) = try startADBProcess(args)

    return ScreenStreamSession(deviceID: deviceID, process: process, stdoutPipe: stdout, stderrPipe: stderr, startedAt: Date())
  }

  // MARK: - Helpers

  private func startADBProcess(_ args: [String]) throws -> (process: Process, stdout: Pipe, stderr: Pipe) {
    guard let url = adbURL else {
      throw ADBError.adbNotFound
    }
    guard FileManager.default.fileExists(atPath: url.path) else { throw ADBError.adbNotFound }

    let ok = url.startAccessingSecurityScopedResource()
    defer { if ok { url.stopAccessingSecurityScopedResource() } }

    let process = Process()
    let stdout = Pipe()
    let stderr = Pipe()
    process.executableURL = url
    process.arguments = args
    process.standardOutput = stdout
    process.standardError = stderr

    log.debug("Run adb \(url.path, privacy: .public) with \(String(describing: args), privacy: .public)")
    try process.run()
    return (process, stdout, stderr)
  }

  func pull(deviceID: String, remote: String, to localURL: URL) throws {
    try FileManager.default.createDirectory(at: localURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    _ = try runString(["-s", deviceID, "pull", remote, localURL.path])
  }

  func getProp(deviceID: String, key: String) throws -> String {
    try runString(["-s", deviceID, "shell", "getprop", key])
  }

  func screenDensityScale(deviceID: String) throws -> CGFloat {
    if let wmOutput = try? runString(["-s", deviceID, "shell", "wm", "density"]) {
      if let match = wmOutput.firstMatch(of: /Physical density:\s*(\d+)/) {
        if let value = Double(match.1) {
          return CGFloat(value) / 160.0
        }
      }
    }

    if let prop = try? getProp(deviceID: deviceID, key: "ro.sf.lcd_density") {
      if let value = Double(prop.trimmingCharacters(in: .whitespacesAndNewlines)) {
        return CGFloat(value) / 160.0
      }
    }

    throw ADBError.parseFailure("Unable to determine device density")
  }

  func getCurrentDisplaySize(deviceID: String) throws -> String {
    let result = try runString(["-s", deviceID, "shell", "dumpsys", "window", "displays"])
    guard let match = result.firstMatch(of: /cur=(?<size>\d+x\d+)/) else {
      throw ADBError.parseFailure("Unable to find window size")
    }
    return String(match.output.size)
  }

  func runData(_ args: [String]) throws -> Data {
    let (process, stdout, stderr) = try startADBProcess(args)

    // Drain stdout; this returns when pipe gets EOF (process closes).
    let outData = stdout.fileHandleForReading.readDataToEndOfFile()

    // Ensure termination status is observed.
    process.waitUntilExit()
    let status = process.terminationStatus
    if status != 0 {
      let errData = stderr.fileHandleForReading.readDataToEndOfFile()
      let errString = String(data: errData, encoding: .utf8)
      log.error("adb failed status=\(status) \(errString ?? "unknown")")
      throw ADBError.nonZeroExit(status, stderr: errString)
    }
    return outData
  }

  func runString(_ args: [String]) throws -> String {
    let data = try runData(args)
    guard let str = String(data: data, encoding: .utf8) else {
      throw ADBError.parseFailure("non-utf8 output")
    }
    return str
  }
}
