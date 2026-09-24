import Foundation
@testable import Snap_O
import Testing

@Suite("Live preview rotation", .timeLimit(.minutes(1)))
@MainActor
struct LivePreviewRotationTests {
  @Test("rotates left and right with wraparound", arguments: [
    (current: 0, left: true, target: 1), (current: 3, left: true, target: 0),
    (current: 0, left: false, target: 3), (current: 1, left: false, target: 0)
  ])
  func directions(example: (current: Int, left: Bool, target: Int)) async throws {
    let shell = RotationShell()
    let session = shell.session(rotation: example.current)
    try await session.rotate(left: example.left)
    #expect(shell.commands.last?.hasPrefix("wm user-rotation lock \(example.target) ") == true)
    await session.stop()
  }

  @Test("restores the mode saved before the first rotation", arguments: ["free", "lock 2"])
  func restoresOriginal(mode: String) async throws {
    let shell = RotationShell(mode: mode)
    let session = shell.session()
    try await session.rotate(left: true)
    shell.mode = "lock 1"
    try await session.rotate(left: false)
    await session.stop()
    #expect(shell.commands.last?.hasPrefix("wm user-rotation \(mode) ") == true)
  }

  @Test("rejects unsupported rotation modes", arguments: ["", "lock 4", "Error: unknown command"])
  func unsupportedMode(mode: String) async {
    let shell = RotationShell(mode: mode)
    let session = shell.session()
    await #expect(throws: ADBError.self) { try await session.rotate(left: true) }
    await session.stop()
  }

  @Test("reports unsuccessful shell responses", arguments: [
    "Error: unsupported\nSNAPO_ROTATION_EXIT:0\n", "SNAPO_ROTATION_EXIT:1\n", ""
  ])
  func failedWrite(output: String) async {
    let shell = RotationShell()
    shell.writeOutput = output
    let session = shell.session()
    await #expect(throws: ADBError.self) { try await session.rotate(left: true) }
    shell.writeOutput = "SNAPO_ROTATION_EXIT:0\n"
    await session.stop()
  }

  @Test("restores settings after a failed rotation write")
  func restoresAfterFailure() async {
    let shell = RotationShell()
    let session = shell.session()
    shell.writeOutput = "SNAPO_ROTATION_EXIT:1\n"
    _ = try? await session.rotate(left: true)
    shell.writeOutput = "SNAPO_ROTATION_EXIT:0\n"
    await session.stop()
    #expect(shell.commands.last?.hasPrefix("wm user-rotation free ") == true)
  }

  @Test("restoration follows an in-flight write when its caller is cancelled")
  func cancelledCaller() async throws {
    let shell = RotationShell()
    let entered = AsyncStream<Void>.makeStream()
    let release = AsyncStream<Void>.makeStream()
    let session = LivePreviewRotation(runShell: { command in
      if command.hasPrefix("wm user-rotation lock") {
        entered.continuation.yield(())
        for await _ in release.stream {
          break
        }
      }
      return shell.run(command)
    }, readRotation: { 0 }, waitForRotation: {})
    let rotation = Task { try await session.rotate(left: true) }
    for await _ in entered.stream {
      break
    }
    rotation.cancel()
    let stop = Task { await session.stop() }
    release.continuation.yield(())
    try await rotation.value
    await stop.value
    let commands = shell.commands.map { String($0.split(separator: " 2>&1")[0]) }
    #expect(commands == ["wm user-rotation", "wm user-rotation lock 1", "wm user-rotation free"])
  }

  @Test("emulator rotation leaves Android settings untouched")
  func emulatorAvoidsSettings() async throws {
    let shell = RotationShell()
    let session = LivePreviewRotation(runShell: shell.run, readRotation: { 0 }, rotateEmulator: { _ in })
    try await session.rotate(left: true)
    await session.stop()
    #expect(shell.commands.isEmpty)
  }

  @Test("stops waiting once Android applies the rotation")
  func rotationSettles() async throws {
    var current = 0
    var waits = 0
    let shell = RotationShell()
    let session = LivePreviewRotation(runShell: shell.run, readRotation: { current }, waitForRotation: {
      waits += 1
      current = 1
    })
    try await session.rotate(left: true)
    #expect(waits == 1)
    await session.stop()
  }

  @Test("accepts an app retaining its fixed orientation")
  func lockedApp() async throws {
    let shell = RotationShell()
    let session = shell.session(rotation: 0)
    try await session.rotate(left: true)
    await session.stop()
  }
}

@MainActor
private final class RotationShell {
  var commands: [String] = []
  var writeOutput = "SNAPO_ROTATION_EXIT:0\n"
  var mode: String

  init(mode: String = "free") {
    self.mode = mode
  }

  func session(rotation: Int = 0) -> LivePreviewRotation {
    LivePreviewRotation(runShell: run, readRotation: { rotation }, waitForRotation: {})
  }

  func run(_ command: String) -> String {
    commands.append(command)
    return command == "wm user-rotation" ? mode : writeOutput
  }
}
