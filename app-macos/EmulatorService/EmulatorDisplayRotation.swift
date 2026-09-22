import Foundation

struct EmulatorDisplayRotation {
  let shell: ([String]) throws -> String

  func rotate(quarterTurns: Int) throws {
    let current = try rotation()
    let target = (current + quarterTurns) % 4
    try command(["cmd", "window", "fixed-to-user-rotation", "enabled"])
    try command(["cmd", "window", "user-rotation", "lock", String(target)])

    // Restart screenrecord only after Android has applied the new display dimensions.
    let deadline = Date().addingTimeInterval(3)
    repeat {
      if try rotation() == target { return }
      Thread.sleep(forTimeInterval: 0.1)
    } while Date() < deadline
    throw EmulatorServiceError(message: "Android did not apply the requested rotation. Try again.")
  }

  private func rotation() throws -> Int {
    let output = try shell(["dumpsys", "input"])
    for line in output.split(whereSeparator: \.isNewline) {
      guard line.contains("Viewport"), line.contains("displayId=0,"),
            let match = line.firstMatch(of: /orientation=([0-3])(?:,|\s|$)/),
            let rotation = Int(match.1) else { continue }
      return rotation
    }
    throw EmulatorServiceError(message: "Could not determine the emulator's display rotation.")
  }

  private func command(_ arguments: [String]) throws {
    let output = try shell(arguments).trimmingCharacters(in: .whitespacesAndNewlines)
    guard output.isEmpty else {
      throw EmulatorServiceError(message: "Android could not change display rotation: \(output)")
    }
  }
}
