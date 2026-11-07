import Foundation

@MainActor
struct EmulatorDisplayProbeTests {
  static func run() async throws {
    try await suppliesOnlyItsCapturedTarget()
    try await shutdownJoinsPendingRead()
    print("Emulator display probe tests passed")
  }

  private static func response(_ probe: EmulatorDisplayProbe) async -> (String?, String?) {
    await withCheckedContinuation { continuation in
      probe.readDisplay { continuation.resume(returning: ($0, $1)) }
    }
  }

  private static func suppliesOnlyItsCapturedTarget() async throws {
    let target = DeviceTarget(serial: "emulator-5554", transportID: "42")
    let probe = try EmulatorDisplayProbe(target: target) { actual in
      precondition(actual == target)
      return "Physical size: 1080x2400"
    }
    let result = await response(probe)
    precondition(result.0 == "Physical size: 1080x2400" && result.1 == nil)
    await probe.shutdown()
    let stopped = await response(probe)
    precondition(stopped.0 == nil && stopped.1 != nil)
  }

  private static func shutdownJoinsPendingRead() async throws {
    let target = DeviceTarget(serial: "emulator-5554", transportID: "42")
    let gate = TestSuspension()
    let probe = try EmulatorDisplayProbe(target: target) { actual in
      precondition(actual == target)
      try await gate.wait()
      return "stale display"
    }
    let pending = Task { await response(probe) }
    await gate.waitUntilStarted()
    target.invalidate()
    let finished = TestValue(false)
    let shutdown = await startTestTask {
      await probe.shutdown()
      finished.value = true
    }
    precondition(!finished.value, "Shutdown must join the actual read")
    let replacement = DeviceTarget(serial: target.serial, transportID: "43")
    precondition(replacement.isValid)
    let rejected = await response(probe)
    precondition(rejected.0 == nil && rejected.1 != nil)
    gate.resume()
    let late = await pending.value
    precondition(late.0 == nil && late.1 != nil && gate.wasCancelled)
    await shutdown.value
    precondition(finished.value && replacement.isValid)
  }
}
