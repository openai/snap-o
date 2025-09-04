import CoreGraphics
import Foundation

struct ADBExec {
  let url: URL

  struct ExecProcess {
    let process: Process
    let stdout: Pipe
    let stderr: Pipe
  }

  func startProcess(_ args: [String]) throws -> ExecProcess {
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

    try process.run()
    return ExecProcess(process: process, stdout: stdout, stderr: stderr)
  }

  func runData(_ args: [String]) async throws -> Data {
    let handles = try startProcess(args)
    return try await Task(priority: .userInitiated) { () -> Data in
      let outData = handles.stdout.fileHandleForReading.readDataToEndOfFile()
      handles.process.waitUntilExit()
      let status = handles.process.terminationStatus
      if status != 0 {
        let errData = handles.stderr.fileHandleForReading.readDataToEndOfFile()
        let errString = String(data: errData, encoding: .utf8)
        throw ADBError.nonZeroExit(status, stderr: errString)
      }
      return outData
    }.value
  }

  func runString(_ args: [String]) async throws -> String {
    let data = try await runData(args)
    guard let str = String(data: data, encoding: .utf8) else {
      throw ADBError.parseFailure("non-utf8 output")
    }
    return str
  }
}

extension ADBExec {
  func screencapPNG(deviceID: String) async throws -> Data {
    try await runData(["-s", deviceID, "shell", "screencap -p 2>/dev/null"])
  }

  func startScreenrecord(
    deviceID: String,
    bitRateMbps: Int = 8,
    timeLimitSeconds: Int = 60 * 60 * 3,
    size: String? = nil
  ) async throws -> RecordingSession {
    let sizeArg: String? = if let provided = size, !provided.isEmpty {
      provided
    } else {
      try? await getCurrentDisplaySize(deviceID: deviceID)
    }
    let remote = "/data/local/tmp/snapo_recording_\(UUID().uuidString).mp4"

    var args = [
      "-s", deviceID, "shell", "screenrecord",
      "--bit-rate", "\(bitRateMbps * 1_000_000)",
      "--time-limit", "\(timeLimitSeconds)"
    ]
    if let sizeArg, !sizeArg.isEmpty { args += ["--size", sizeArg] }
    args += [remote]

    let handles = try startProcess(args)
    return RecordingSession(
      deviceID: deviceID,
      remotePath: remote,
      process: handles.process,
      stderrPipe: handles.stderr,
      startedAt: Date()
    )
  }

  func stopScreenrecord(session: RecordingSession, deviceID: String, savingTo localURL: URL) async throws {
    session.process.terminate()
    session.process.waitUntilExit()
    let status = session.process.terminationStatus
    if status != 0, status != 15 {
      let data = try? session.stderrPipe.fileHandleForReading.readToEnd() ?? Data()
      let err = data.flatMap { String(data: $0, encoding: .utf8) }
      throw ADBError.nonZeroExit(session.process.terminationStatus, stderr: err)
    }
    // Give device time to flush the file before pulling
    try? await Task.sleep(nanoseconds: 1_000_000_000)
    try await pull(deviceID: session.deviceID, remote: session.remotePath, to: localURL)
    _ = try? await runString(["-s", session.deviceID, "shell", "rm", "-f", session.remotePath])
  }

  func startScreenStream(deviceID: String, bitRateMbps: Int = 8, size: String? = nil) async throws -> ScreenStreamSession {
    var args = [
      "-s", deviceID, "shell",
      "screenrecord",
      "--output-format=h264",
      "--bit-rate", "\(bitRateMbps * 1_000_000)",
      "--time-limit", "0"
    ]
    if let size, !size.isEmpty { args += ["--size", size] }
    args += ["-"]

    let handles = try startProcess(args)
    _ = try? await keyEvent(deviceID: deviceID, keyCode: "KEYCODE_WAKEUP")
    return ScreenStreamSession(
      deviceID: deviceID,
      process: handles.process,
      stdoutPipe: handles.stdout,
      stderrPipe: handles.stderr,
      startedAt: Date()
    )
  }

  // MARK: - Other Commands

  func screenDensityScale(deviceID: String) async throws -> CGFloat {
    if let wmOutput = try? await runString(["-s", deviceID, "shell", "wm", "density"]) {
      if let match = wmOutput.firstMatch(of: /Physical density:\s*(\d+)/) {
        if let value = Double(match.1) { return CGFloat(value) / 160.0 }
      }
    }
    if let prop = try? await runString(["-s", deviceID, "shell", "getprop", "ro.sf.lcd_density"]) {
      if let value = Double(prop.trimmingCharacters(in: .whitespacesAndNewlines)) {
        return CGFloat(value) / 160.0
      }
    }
    throw ADBError.parseFailure("Unable to determine device density")
  }

  @discardableResult
  func keyEvent(deviceID: String, keyCode: String) async throws -> String {
    try await runString(["-s", deviceID, "shell", "input", "keyevent", keyCode])
  }

  func getProp(deviceID: String, key: String) async throws -> String {
    try await runString(["-s", deviceID, "shell", "getprop", key])
  }

  func setShowTouches(deviceID: String, enabled: Bool) async throws {
    _ = try await runString([
      "-s", deviceID, "shell", "settings", "put", "system", "show_touches", enabled ? "1" : "0"
    ])
  }

  func getShowTouches(deviceID: String) async throws -> Bool {
    let value = try await runString([
      "-s", deviceID, "shell", "settings", "get", "system", "show_touches"
    ]).trimmingCharacters(in: .whitespacesAndNewlines)
    return value == "1"
  }

  func pull(deviceID: String, remote: String, to localURL: URL) async throws {
    try FileManager.default.createDirectory(at: localURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    _ = try await runString(["-s", deviceID, "pull", remote, localURL.path])
  }

  func getCurrentDisplaySize(deviceID: String) async throws -> String {
    let result = try await runString(["-s", deviceID, "shell", "dumpsys", "window", "displays"])
    guard let match = result.firstMatch(of: /cur=(?<size>\d+x\d+)/) else {
      throw ADBError.parseFailure("Unable to find window size")
    }
    return String(match.output.size)
  }

  // Fetch and parse all system properties (or only those with a given prefix).
  // Output lines are like: [ro.product.model]: [Pixel 7]
  func getProperties(deviceID: String, prefix: String? = nil) async throws -> [String: String] {
    let output = try await runString(["-s", deviceID, "shell", "getprop"]) // full dump
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

  func trackDevices() throws -> (handles: ExecProcess, stream: AsyncThrowingStream<String, Error>) {
    enum EOF: Error { case reached }

    let handles = try startProcess(["track-devices", "-l"])
    let fh = handles.stdout.fileHandleForReading

    func readExactly(_ count: Int) throws -> Data {
      var remaining = count
      var out = Data()
      while remaining > 0 {
        if Task.isCancelled { throw CancellationError() }
        guard let chunk = try fh.read(upToCount: remaining) else { throw EOF.reached }
        if chunk.isEmpty { throw EOF.reached }
        out.append(chunk)
        remaining -= chunk.count
      }
      return out
    }

    let stream = AsyncThrowingStream<String, Error> { continuation in
      let streamTask = Task(priority: .userInitiated) {
        defer { continuation.finish() }
        do {
          while true {
            // 4 ASCII hex digits -> payload length
            let header = try readExactly(4)
            guard let hex = String(data: header, encoding: .ascii),
                  let len = Int(hex, radix: 16)
            else {
              // realign by skipping one byte and keep going
              _ = try? fh.read(upToCount: 1)
              continue
            }

            let payload = try readExactly(len)
            if let payloadString = String(data: payload, encoding: .utf8) {
              continuation.yield(payloadString)
            }
          }
        } catch is CancellationError {
          // cancelled by caller; just finish
        } catch EOF.reached {
          // clean EOF; finish
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { _ in streamTask.cancel() }
    }

    return (handles, stream)
  }
}
