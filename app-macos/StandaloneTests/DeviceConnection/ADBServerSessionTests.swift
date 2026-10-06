import Darwin
import Foundation

struct ADBServerSessionTests {
  static func run() async throws {
    try await trackingPublishesOnlyAnchoredSnapshot()
    try await restartBeforeTrackerEOFRejectsReusedTransport()
    try await failedSelectionKeepsHealthyServer()
    try await deviceSelectionDoesNotOwnServerProof()
    try cancellationClosesPendingSetup()
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

  private static func cancellationClosesPendingSetup() throws {
    let entered = ScriptGate()
    let server = ScriptedADBServer([
      [.closed],
      [.stall("host:transport-id:42", entered), .closed]
    ])
    let initial = try server.connect()
    let session = ADBServerSession(tracking: initial, timeout: .seconds(30), connectionFactory: server.connect)
    let completed = DispatchGroup()
    completed.enter()
    DispatchQueue.global().async {
      defer { completed.leave() }
      do {
        _ = try session.prepareTracking(transportID: "42", replacing: initial)
        preconditionFailure("Cancelled bootstrap must fail")
      } catch {}
    }
    entered.wait()
    session.close()
    completed.wait()
    let late = DeviceTarget(serial: "late", transportID: "42", server: session)
    precondition(!late.isValid)
    server.finish()
  }

  private static func payload(_ text: String) -> String {
    String(format: "%04X", text.utf8.count) + text
  }
}

final class ScriptGate: @unchecked Sendable {
  private let event = DispatchSemaphore(value: 0)
  private let lock = NSLock()
  private var reached = false
  var wasReached: Bool { lock.withLock { reached } }
  func signal() { lock.withLock { reached = true }; event.signal() }
  func wait() { event.wait() }
}

final class ScriptedADBServer: @unchecked Sendable {
  enum Step: Sendable {
    case reply(String, String)
    case disconnectOnRequest(String, ScriptGate)
    case stall(String, ScriptGate)
    case closed
  }
  private let lock = NSLock()
  private let workers = DispatchGroup()
  private var scripts: [[Step]]

  init(_ scripts: [[Step]]) { self.scripts = scripts }
  var client: ADBClient { ADBClient(discoveryTimeout: .seconds(2), connectionFactory: connect) }

  func connect() throws -> ADBSocketConnection {
    let steps = lock.withLock {
      precondition(!scripts.isEmpty, "Unexpected ADB connection")
      return scripts.removeFirst()
    }
    var pair: [Int32] = [0, 0]
    guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else { throw POSIXError(.EIO) }
    let peer = pair[1]
    workers.enter()
    DispatchQueue.global().async { [workers] in
      defer { Darwin.close(peer); workers.leave() }
      for step in steps {
        switch step {
        case .reply(let expected, let response):
          precondition(Self.request(peer) == expected, "Unexpected ADB request, expected \(expected)")
          Self.write(response, to: peer)
        case .disconnectOnRequest(let expected, let gate):
          precondition(Self.request(peer) == expected)
          gate.signal()
          return
        case .stall(let expected, let gate):
          precondition(Self.request(peer) == expected)
          gate.signal()
        case .closed:
          var byte: UInt8 = 0
          precondition(Darwin.read(peer, &byte, 1) == 0, "Unexpected device request after failed proof")
        }
      }
    }
    return ADBSocketConnection(connectedSocket: pair[0])
  }

  func finish() {
    workers.wait()
    precondition(lock.withLock { scripts.isEmpty }, "Missing ADB connections")
  }

  private static func request(_ socket: Int32) -> String {
    let header = String(decoding: read(socket, count: 4), as: UTF8.self)
    guard let count = Int(header, radix: 16) else { preconditionFailure("Invalid request header") }
    return String(decoding: read(socket, count: count), as: UTF8.self)
  }

  private static func read(_ socket: Int32, count: Int) -> Data {
    var bytes = Data(count: count)
    bytes.withUnsafeMutableBytes { buffer in
      var offset = 0
      while offset < count {
        let size = Darwin.read(socket, buffer.baseAddress!.advanced(by: offset), count - offset)
        precondition(size > 0, "Missing request")
        offset += size
      }
    }
    return bytes
  }

  private static func write(_ response: String, to socket: Int32) {
    Data(response.utf8).withUnsafeBytes { buffer in
      var offset = 0
      while offset < buffer.count {
        let size = Darwin.write(socket, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
        precondition(size > 0)
        offset += size
      }
    }
  }
}
