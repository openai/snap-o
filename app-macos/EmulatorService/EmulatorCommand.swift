import Foundation

struct EmulatorServiceError: LocalizedError {
  let message: String
  var errorDescription: String? {
    message
  }
}

/// Short SDK commands run on the service's serial worker, never the app's main thread.
struct EmulatorCommand {
  let executable: URL
  let arguments: [String]

  func run(timeout: TimeInterval = 5) throws -> String {
    let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    FileManager.default.createFile(atPath: outputURL.path, contents: nil)
    defer { try? FileManager.default.removeItem(at: outputURL) }
    let output = try FileHandle(forWritingTo: outputURL)
    defer { try? output.close() }
    let process = Process()
    process.executableURL = executable
    process.arguments = arguments
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = output
    process.standardError = output
    try process.run()
    let deadline = Date().addingTimeInterval(timeout)
    while process.isRunning, Date() < deadline {
      Thread.sleep(forTimeInterval: 0.05)
    }
    if process.isRunning {
      process.terminate()
      Thread.sleep(forTimeInterval: 0.1)
      if process.isRunning { kill(process.processIdentifier, SIGKILL) }
      process.waitUntilExit()
      throw EmulatorServiceError(message: "The Android SDK command timed out. Try again.")
    }
    process.waitUntilExit()
    let input = try FileHandle(forReadingFrom: outputURL)
    defer { try? input.close() }
    let data = try input.read(upToCount: 64 * 1024) ?? Data()
    guard let output = String(data: data, encoding: .utf8) else {
      throw EmulatorServiceError(message: "The Android SDK command returned invalid text.")
    }
    let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
    guard process.terminationStatus == 0 else {
      throw EmulatorServiceError(message: text.isEmpty ? "The Android SDK command failed." : String(text.suffix(1500)))
    }
    return text
  }
}
