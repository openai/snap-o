import Clocks
import Dependencies
import Foundation

@main
struct EmulatorDiscoveryTests {
  static func main() async throws {
    try await ADBServerSessionTests.run()
    try await EmulatorDisplayProbeTests.run()
    try await AndroidHostControlTests.run()
    try await bootProbeUsesDiscoveredTransport()
    try await replacedTransportDiscardsBootResult()
    try await missingTransportDoesNotProbe()
    try await offlineEmulatorDoesNotProbe()
    try await failedSelectionDoesNotSendShell()
    try await restartedServerDiscardsBootResult()
    try await stalledInitialSnapshotTimesOut()
    print("Emulator discovery connection tests passed")
  }

  private static let row = "emulator-5554 device transport_id:42\n"

  private static func discovery(_ row: String) -> [[ScriptedADBServer.Step]] {
    [
      [.reply("host:track-devices-l", "OKAY" + payload(row)), .closed],
      [.reply("host:transport-id:42", "OKAY"), .reply("host:version", "OKAY00040029")],
      [.reply("host:track-devices-l", "OKAY" + payload(row)), .closed],
      [.reply("host:version", "OKAY00040029")]
    ]
  }

  private static func boot(guardReply: String = "OKAY00040029") -> [[ScriptedADBServer.Step]] {
    [
      [.reply("host:transport-id:42", "OKAY"), .reply("shell:getprop sys.boot_completed", "OKAY1\n")],
      [.reply("host:version", guardReply)]
    ]
  }

  private static func finalList(_ row: String) -> [[ScriptedADBServer.Step]] {
    [
      [.reply("host:devices-l", "OKAY" + payload(row))],
      [.closed]
    ]
  }

  private static func bootProbeUsesDiscoveredTransport() async throws {
    let server = ScriptedADBServer(discovery(row) + boot() + finalList(row))
    let connections = try await server.client.emulatorConnections()
    server.finish()
    precondition(connections.count == 1 && connections[0].state == .running)
  }

  private static func replacedTransportDiscardsBootResult() async throws {
    let current = "emulator-5554 device transport_id:43\n"
    let server = ScriptedADBServer(discovery(row) + boot() + finalList(current))
    let connections = try await server.client.emulatorConnections()
    server.finish()
    precondition(connections.count == 1 && connections[0].transportID == "43")
    precondition(connections[0].state == .starting, "Old boot completion must not describe the replacement")
  }

  private static func missingTransportDoesNotProbe() async throws {
    for transport in ["", " transport_id:0", " transport_id:invalid"] {
      let row = "emulator-5554 device\(transport)\n"
      let server = ScriptedADBServer([
        [.reply("host:track-devices-l", "OKAY" + payload(row)), .closed],
        [.reply("host:devices-l", "OKAY" + payload(row))]
      ])
      let connections = try await server.client.emulatorConnections()
      server.finish()
      precondition(connections.count == 1 && connections[0].state == .starting)
    }
  }

  private static func offlineEmulatorDoesNotProbe() async throws {
    let row = "emulator-5554 offline transport_id:42\n"
    let server = ScriptedADBServer([
      [.reply("host:track-devices-l", "OKAY" + payload(row)), .closed],
      [.reply("host:devices-l", "OKAY" + payload(row))]
    ])
    let connections = try await server.client.emulatorConnections()
    server.finish()
    precondition(connections.count == 1 && connections[0].state == .offline)
  }

  private static func failedSelectionDoesNotSendShell() async throws {
    let server = ScriptedADBServer(discovery(row) + [
      [.reply("host:transport-id:42", "FAIL" + payload("device not found")), .closed],
      [.closed]
    ] + finalList(row))
    let connections = try await server.client.emulatorConnections()
    server.finish()
    precondition(connections.count == 1 && connections[0].state == .starting)
  }

  private static func restartedServerDiscardsBootResult() async throws {
    // The boot check succeeds, then the old server cannot prove the final list.
    // Even a replacement with the same serial and transport ID must remain starting.
    let server = ScriptedADBServer(discovery(row) + boot(guardReply: "FAIL" + payload("server ended")) +
      finalList(row) + [[.reply("host:devices-l", "OKAY" + payload(row))]])
    let connections = try await server.client.emulatorConnections()
    server.finish()
    precondition(connections.count == 1 && connections[0].state == .starting)
  }

  private static func stalledInitialSnapshotTimesOut() async throws {
    let timing = SnapshotClock()
    let server = ScriptedADBServer([[.reply("host:track-devices-l", "OKAY"), .closed]])
    let client = withDependencies { $0.continuousClock = timing } operation: { server.client }
    let discovery = Task { try await client.emulatorConnections() }
    timing.sleepRequested.wait()
    await timing.base.advance(by: .seconds(2))
    do {
      _ = try await discovery.value
      preconditionFailure("A server that omits its initial snapshot must time out")
    } catch ADBError.requestTimedOut {} catch { throw error }
    server.finish()
  }

  private static func payload(_ value: String) -> String {
    String(format: "%04X", value.utf8.count) + value
  }
}

private struct SnapshotClock: Clock {
  let base = TestClock<Duration>()
  let sleepRequested = ScriptGate()
  var now: TestClock<Duration>.Instant { base.now }
  var minimumResolution: Duration { base.minimumResolution }
  func sleep(until deadline: TestClock<Duration>.Instant, tolerance: Duration?) async throws {
    sleepRequested.signal()
    try await base.sleep(until: deadline, tolerance: tolerance)
  }
}
