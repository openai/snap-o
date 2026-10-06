import Foundation

enum ADBServerSessionTests {
  static func run() async throws {
    try await trackingPublishesOnlyAnchoredSnapshot()
    try await restartBeforeTrackerEOFRejectsReusedTransport()
    try await failedSelectionKeepsHealthyServer()
    try await deviceSelectionDoesNotOwnServerProof()
    try await cancellationClosesPendingSetup()
    print("ADB server lifetime tests passed")
  }

  private static let row = "pixel device model:Original transport_id:42\n"

  private static func trackingPublishesOnlyAnchoredSnapshot() async throws {
    let actual = "pixel device model:Current transport_id:43\n"
    let server = ScriptedADBServer([
      [.reply("host:track-devices-l", "OKAY" + payload("") + payload(row)), .closed],
      [.reply("host:transport-id:42", "OKAY"), .reply("host:version", "OKAY00040029")],
      [.reply("host:track-devices-l", "OKAY" + payload(actual)), .closed],
      [.reply("host:version", "OKAY00040029")],
      [.reply("host:transport-id:43", "OKAY"), .reply("shell:echo ready", "OKAYready")],
      [.closed]
    ])
    let (handle, stream) = try await server.client.trackDevices()
    var iterator = stream.makeAsyncIterator()
    let empty = try await iterator.next()
    precondition(empty == "")
    let snapshot = try await iterator.next()
    precondition(snapshot == actual, "The unanchored candidate snapshot must be discarded")
    let target = DeviceTarget(serial: "pixel", transportID: "43", server: handle.server)
    let output = try await server.client.bound(to: target).runShellString(deviceID: "pixel", command: "echo ready")
    precondition(output == "ready" && target.isValid)
    handle.cancel()
    server.finish()
    precondition(!target.isValid)
  }

  private static func restartBeforeTrackerEOFRejectsReusedTransport() async throws {
    let proof = ScriptGate()
    let server = ScriptedADBServer([
      [.reply("host:track-devices-l", "OKAY" + payload(row)), .closed],
      [.reply("host:transport-id:42", "OKAY"), .reply("host:version", "OKAY00040029")],
      [.reply("host:track-devices-l", "OKAY" + payload(row)), .closed],
      [.disconnectOnRequest("host:version", proof)],
      // The replacement accepts the reused ID, but must never receive a shell request.
      [.reply("host:transport-id:42", "OKAY"), .closed],
      [.closed]
    ])
    let (handle, stream) = try await server.client.trackDevices()
    var iterator = stream.makeAsyncIterator()
    _ = try await iterator.next()
    let target = DeviceTarget(serial: "pixel", transportID: "42", server: handle.server)
    let sibling = DeviceTarget(serial: "other", transportID: "9", server: handle.server)
    do {
      _ = try await server.client.bound(to: target).runShellString(deviceID: "pixel", command: "input keyevent 3")
      preconditionFailure("An operation on a replacement server must fail")
    } catch {}
    precondition(proof.wasReached && !target.isValid && !sibling.isValid)
    handle.cancel()
    server.finish()
  }

  private static func failedSelectionKeepsHealthyServer() async throws {
    let server = ScriptedADBServer([
      [.reply("host:track-devices-l", "OKAY" + payload(row)), .closed],
      [.reply("host:transport-id:42", "OKAY"), .reply("host:version", "OKAY00040029")],
      [.reply("host:track-devices-l", "OKAY" + payload(row)), .closed],
      [.reply("host:version", "OKAY00040029")],
      [.reply("host:transport-id:9", "FAIL" + payload("device not found")), .closed],
      [.closed],
      [.reply("host:transport-id:42", "OKAY"), .reply("shell:echo healthy", "OKAYhealthy")],
      [.closed]
    ])
    let (handle, stream) = try await server.client.trackDevices()
    var iterator = stream.makeAsyncIterator()
    _ = try await iterator.next()
    let removed = DeviceTarget(serial: "removed", transportID: "9", server: handle.server)
    let healthy = DeviceTarget(serial: "pixel", transportID: "42", server: handle.server)
    do {
      _ = try await server.client.bound(to: removed).runShellString(deviceID: "removed", command: "echo missing")
      preconditionFailure("Removed transport selection must fail")
    } catch {}
    let output = try await server.client.bound(to: healthy).runShellString(deviceID: "pixel", command: "echo healthy")
    precondition(output == "healthy" && healthy.isValid)
    handle.cancel()
    server.finish()
  }

  private static func deviceSelectionDoesNotOwnServerProof() async throws {
    let server = ScriptedADBServer([
      [.reply("host:track-devices-l", "OKAY" + payload(row)), .closed],
      [.reply("host:transport-id:42", "OKAY"), .reply("host:version", "OKAY00040029")],
      [.reply("host:track-devices-l", "OKAY" + payload(row)), .closed],
      [.reply("host:version", "OKAY00040029")],
      [.reply("host:transport-id:42", "OKAY"), .reply("shell:echo first", "OKAYfirst")],
      [.reply("host:version", "OKAY00040029")],
      [.reply("host:transport-id:9", "OKAY"), .reply("shell:echo second", "OKAYsecond")],
      [.closed]
    ])
    let (handle, stream) = try await server.client.trackDevices()
    var iterator = stream.makeAsyncIterator()
    _ = try await iterator.next()
    let first = DeviceTarget(serial: "pixel", transportID: "42", server: handle.server)
    let second = DeviceTarget(serial: "second", transportID: "9", server: handle.server)
    let firstResult = try await server.client.bound(to: first).runShellString(deviceID: "pixel", command: "echo first")
    let secondResult = try await server.client.bound(to: second).runShellString(deviceID: "second", command: "echo second")
    precondition(firstResult == "first" && secondResult == "second")
    precondition(first.isValid && second.isValid)
    handle.cancel()
    server.finish()
  }

  private static func cancellationClosesPendingSetup() async throws {
    let entered = ScriptGate()
    let server = ScriptedADBServer([
      [.closed],
      [.stall("host:transport-id:42", entered), .closed]
    ])
    let initial = try server.connect()
    let session = ADBServerSession(tracking: initial, timeout: .seconds(30), connectionFactory: server.connect)
    let completed = Task.detached {
      do {
        _ = try session.prepareTracking(transportID: "42", replacing: initial)
        preconditionFailure("Cancelled bootstrap must fail")
      } catch {}
    }
    try await entered.wait()
    session.close()
    await completed.value
    let late = DeviceTarget(serial: "late", transportID: "42", server: session)
    precondition(!late.isValid)
    server.finish()
  }

  private static func payload(_ text: String) -> String {
    String(format: "%04X", text.utf8.count) + text
  }
}

final class ScriptGate: @unchecked Sendable {
  private let event = TestSignal()
  private let lock = NSLock()
  private var reached = false
  var wasReached: Bool {
    lock.withLock { reached }
  }

  func signal() {
    lock.withLock { reached = true }
    event.signal()
  }

  func wait() async throws {
    while true {
      let revision = event.revision
      if wasReached { return }
      try await event.wait(after: revision)
    }
  }
}

final class ScriptedADBServer: @unchecked Sendable {
  enum Step {
    case reply(String, String)
    case disconnectOnRequest(String, ScriptGate)
    case stall(String, ScriptGate)
    case closed
  }

  private let lock = NSLock()
  private var scripts: [[Step]]
  private var connections: [ScriptedADBConnection] = []
  init(_ scripts: [[Step]]) {
    self.scripts = scripts
  }

  var client: ADBClient {
    ADBClient(discoveryTimeout: .seconds(2), connectionFactory: connect)
  }

  func connect() throws -> any ADBConnection {
    let script = lock.withLock {
      precondition(!scripts.isEmpty, "Unexpected ADB connection")
      return Script(scripts.removeFirst())
    }
    let connection = ScriptedADBConnection(reads: [])
    script.connection = connection
    connection.respond = { try script.respond($0) }
    lock.withLock { connections.append(connection) }
    return connection
  }

  func finish() {
    let active = lock.withLock { connections }
    precondition(active.allSatisfy(\.isClosed), "Every connection must be released")
    precondition(lock.withLock { scripts.isEmpty }, "Missing ADB connections")
  }

  private final class Script: @unchecked Sendable {
    weak var connection: ScriptedADBConnection?
    private var steps: [Step]
    init(_ steps: [Step]) {
      self.steps = steps
    }

    func respond(_ command: String) throws -> String? {
      precondition(!steps.isEmpty, "Unexpected command: \(command)")
      switch steps.removeFirst() {
      case .reply(let expected, let response):
        precondition(command == expected, "Expected \(expected), got \(command)")
        if response.hasPrefix("FAIL") { throw ADBError.protocolFailure(String(response.dropFirst(8))) }
        precondition(response.hasPrefix("OKAY"))
        let bytes = Data(response.dropFirst(4).utf8)
        if command == "host:version" { return String(decoding: bytes.dropFirst(4), as: UTF8.self) }
        if command == "host:track-devices-l" || command == "host:devices-l" {
          var remaining = bytes
          while !remaining.isEmpty {
            let count = Int(String(decoding: remaining.prefix(4), as: UTF8.self), radix: 16)!
            remaining = Data(remaining.dropFirst(4))
            connection?.enqueue([.data(Data(remaining.prefix(count)))])
            remaining = Data(remaining.dropFirst(count))
          }
          if command == "host:track-devices-l" { connection?.enqueue([.waitForClose]) }
        } else if command.hasPrefix("shell:") {
          connection?.enqueue([.data(bytes), .end])
        }
        return nil
      case .disconnectOnRequest(let expected, let gate):
        precondition(command == expected)
        gate.signal()
        throw ADBError.serverUnavailable("Synthetic disconnect")
      case .stall(let expected, let gate):
        precondition(command == expected)
        gate.signal()
        try connection?.blockUntilClosed()
        return nil
      case .closed:
        preconditionFailure("Unexpected command after connection ended: \(command)")
      }
    }
  }
}
