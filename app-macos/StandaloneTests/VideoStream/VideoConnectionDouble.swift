import Foundation

/// Simulates blocking device I/O; no real ADB server or helper is used.
final class ADBSocketConnection: @unchecked Sendable {
  private let condition = NSCondition()
  private var bytes = Data([0x53, 0x4E, 0x56, 0x31])
  private var closed = false
  private var mayExit = true
  private var reads = 0
  private var writes = 0

  var isClosed: Bool {
    condition.withLock { closed }
  }

  var readCount: Int {
    condition.withLock { reads }
  }

  var writeCount: Int {
    condition.withLock { writes }
  }

  func holdReaderAfterClose() {
    condition.withLock { mayExit = false }
  }

  func releaseReader() {
    condition.withLock {
      mayExit = true
      condition.broadcast()
    }
  }

  func append(_ data: Data) {
    condition.withLock {
      bytes.append(data)
      condition.broadcast()
    }
  }

  func close() {
    condition.withLock {
      closed = true
      condition.broadcast()
    }
    testChanges.signal()
  }

  func withRequestTimeout<Value>(_ timeout: Duration, _ body: () throws -> Value) rethrows -> Value {
    try body()
  }

  func sendTransport(to deviceID: String) throws {}
  func sendHostCommand(_ command: String, expectsResponse: Bool) throws -> String? {
    nil
  }

  func writeFully(_ bytes: Data) throws {
    condition.withLock { writes += 1 }
    testChanges.signal()
  }

  func readChunk(maxLength: Int) throws -> Data? {
    condition.lock()
    defer { condition.unlock() }
    reads += 1
    testChanges.signal()
    while bytes.isEmpty, !(closed && mayExit) {
      condition.wait()
    }
    guard !closed else { return nil }
    let chunk = bytes.prefix(maxLength)
    bytes.removeFirst(chunk.count)
    return Data(chunk)
  }
}

actor VideoConnectionProbe {
  private var connections: [ADBSocketConnection]
  let startup: TestGate?
  private(set) var opened = 0 {
    didSet { testChanges.signal() }
  }

  init(_ connections: [ADBSocketConnection], startup: TestGate? = nil) {
    self.connections = connections
    self.startup = startup
  }

  func open() async -> ADBSocketConnection {
    opened += 1
    await startup?.wait()
    precondition(!connections.isEmpty, "Unexpected extra video connection")
    return connections.removeFirst()
  }
}

final class VideoConnectionRegistry: @unchecked Sendable {
  static let shared = VideoConnectionRegistry()
  private let lock = NSLock()
  private var probes: [UUID: VideoConnectionProbe] = [:]

  func register(_ probe: VideoConnectionProbe, for target: DeviceTarget) {
    lock.withLock { probes[target.id] = probe }
  }

  func probe(for target: DeviceTarget) -> VideoConnectionProbe {
    lock.withLock { probes[target.id]! }
  }
}

struct ADBClient {
  private var target: DeviceTarget?

  func bound(to target: DeviceTarget) -> Self {
    var client = self
    client.target = target
    return client
  }

  func withTimeout(_ timeout: Duration) -> Self {
    self
  }

  func runShellString(deviceID: String, command: String) async throws -> String {
    preconditionFailure("Video lifetime tests must not request a native identity proof")
  }

  func makeConnection() async throws -> ADBSocketConnection {
    let target = target!
    _ = try target.requireTransport(for: target.serial)
    return await VideoConnectionRegistry.shared.probe(for: target).open()
  }
}
