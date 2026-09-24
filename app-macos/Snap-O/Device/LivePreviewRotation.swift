import Foundation

/// Serializes preview rotation and restores temporary physical-device overrides.
@MainActor
final class LivePreviewRotation {
  private var rotateEmulator: ((Bool) async throws -> Void)?
  private let runShell: (String) async throws -> String
  private let waitForRotation: () async throws -> Void
  private let readRotation: () async throws -> Int
  private var originalMode: String?
  private var operation: Task<Void, Error>?
  private var stopped = false
  private var stopTask: Task<Void, Never>?

  convenience init(deviceID: String) {
    let client = ADBClient().withTimeout(.seconds(5))
    self.init(runShell: { command in
      try await client.runShellString(deviceID: deviceID, command: command)
    }, readRotation: {
      try await client.displayRotation(deviceID: deviceID).rawValue
    })
    if EmulatorGRPCEndpoint.isEmulator(deviceID) {
      rotateEmulator = { left in try await EmulatorRotationClient.rotate(deviceID: deviceID, left: left) }
    }
  }

  init(
    runShell: @escaping (String) async throws -> String,
    readRotation: @escaping () async throws -> Int,
    rotateEmulator: ((Bool) async throws -> Void)? = nil,
    waitForRotation: @escaping () async throws -> Void = { try await Task.sleep(for: .milliseconds(100)) }
  ) {
    self.runShell = runShell
    self.readRotation = readRotation
    self.rotateEmulator = rotateEmulator
    self.waitForRotation = waitForRotation
  }

  func rotate(left: Bool) async throws {
    let previous = operation
    // Finish device writes even if a view disappears, so cleanup can reliably restore them.
    let task = Task {
      _ = try? await previous?.value
      guard !stopped else { throw CancellationError() }
      if let rotateEmulator {
        try await rotateEmulator(left)
        return
      }
      if originalMode == nil {
        originalMode = try await Self.parseMode(runShell("wm user-rotation"))
      }
      let current = try await readRotation()
      guard (0 ... 3).contains(current) else {
        throw ADBError.parseFailure("Unable to determine display rotation.")
      }
      let next = Self.target(from: current, left: left)
      try await setMode("lock \(next)")
      // Apps may retain a fixed orientation. Give Android time to settle without overriding it.
      for _ in 0 ..< 10 {
        if try await readRotation() == next { break }
        try await waitForRotation()
      }
    }
    operation = task
    try await task.value
  }

  func stop() async {
    if let stopTask {
      await stopTask.value
      return
    }
    stopped = true
    let task = Task {
      _ = try? await operation?.value
      guard let originalMode else { return }
      do {
        try await setMode(originalMode)
      } catch {
        SnapOLog.recording.error("Failed to restore device rotation: \(error.localizedDescription, privacy: .public)")
      }
    }
    stopTask = task
    await task.value
  }

  static func target(from current: Int, left: Bool) -> Int {
    (current + (left ? 1 : 3)) % 4
  }

  static func parseMode(_ output: String) throws -> String {
    let mode = output.trimmingCharacters(in: .whitespacesAndNewlines)
    guard mode == "free" || mode.wholeMatch(of: /lock [0-3]/) != nil else {
      throw ADBError.parseFailure("This device does not support rotation control.")
    }
    return mode
  }

  private func setMode(_ mode: String) async throws {
    let output = try await runShell("wm user-rotation \(mode) 2>&1; printf '\\nSNAPO_ROTATION_EXIT:%s\\n' \"$?\"")
    let lines = output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
    guard lines == ["SNAPO_ROTATION_EXIT:0"] else {
      throw ADBError.protocolFailure("The device could not change its rotation. \(output.trimmingCharacters(in: .whitespacesAndNewlines))")
    }
  }
}
