import Clocks
import DependenciesTestSupport
import Foundation
import Testing

@Suite(.dependency(\.continuousClock, TestClock()))
struct ADBDiscoveryTimeoutTests {
  @Test(arguments: ["host:transport:phone", "shell:cat /proc/net/unix", "read"])
  func propagatesTimeoutWithoutRetry(stage: String) async throws {
    let connection = ScriptedADBConnection(
      reads: [.failure(ADBError.requestTimedOut("Synthetic read timeout"))], commandFailure: stage
    )
    let attempts = TestValueCounter()
    let client = ADBClient(discoveryTimeout: .seconds(2)) {
      attempts.increment()
      return connection
    }
    await #expect(throws: ADBError.self) { try await client.listUnixSockets(deviceID: "phone") }
    #expect(attempts.value == 1)
    #expect(connection.isClosed)
    #expect(connection.timeouts.first == .seconds(2))
  }

  @Test(arguments: [false, true])
  func cancellationClosesBlockedRead(bootReadiness: Bool) async throws {
    let connection = ScriptedADBConnection(reads: [.waitForClose])
    defer { connection.close() }
    let client = ADBClient(discoveryTimeout: .seconds(2)) { connection }
    let task = Task {
      if bootReadiness { _ = try await client.isBootComplete(deviceID: "phone") }
      else { _ = try await client.listUnixSockets(deviceID: "phone") }
    }
    defer { task.cancel() }
    try await connection.waitUntilBlocked()
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(connection.isClosed)
  }

  @Test
  func trackingSetupUsesTimeoutAndCancellation() async throws {
    let connection = ScriptedADBConnection(blockedCommand: "host:track-devices-l")
    defer { connection.close() }
    let client = ADBClient(discoveryTimeout: .seconds(2)) { connection }
    let task = Task { try await client.trackDevices() }
    defer { task.cancel() }
    try await connection.waitUntilBlocked()
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(connection.timeouts.first == .seconds(2))
    #expect(connection.isClosed)
  }

  @Test
  func idleTrackingHasNoRequestTimeout() async throws {
    let connection = ScriptedADBConnection(reads: [.data(Data()), .waitForClose])
    defer { connection.close() }
    let client = ADBClient(discoveryTimeout: .seconds(2)) { connection }
    let (handle, stream) = try await client.trackDevices()
    defer { handle.cancel() }
    var iterator = stream.makeAsyncIterator()
    #expect(try await iterator.next() == "")
    try await connection.waitUntilBlocked()
    #expect(connection.ioTimeout == nil)
    handle.cancel()
    #expect(connection.isClosed)
  }

  @Test
  func timeoutScopeRestoresPreviousValueAfterFailure() throws {
    let connection = ScriptedADBConnection()
    try connection.setIOTimeout(.seconds(9))
    #expect(throws: ADBError.self) {
      try connection.withRequestTimeout(.seconds(2)) {
        #expect(connection.ioTimeout == .seconds(2))
        throw ADBError.requestTimedOut("Synthetic failure")
      }
    }
    #expect(connection.ioTimeout == .seconds(9))
  }

  @Test(arguments: ["", "0\n", "1\r\n", "true\n"])
  func readsBootReadiness(output: String) async throws {
    let connection = ScriptedADBConnection(reads: [.data(Data(output.utf8)), .end])
    let client = ADBClient(discoveryTimeout: .seconds(2)) { connection }
    #expect(try await client.isBootComplete(deviceID: "phone") == (output == "1\r\n"))
    #expect(connection.commands == ["host:transport:phone", "shell:getprop sys.boot_completed"])
  }

  @Test(arguments: ["list", "tracking", "properties", "process", "user", "direct"])
  func boundsRequestAndClosesOnFailure(operation: String) async throws {
    let connection = ScriptedADBConnection(
      reads: [.failure(ADBError.requestTimedOut("Synthetic failure"))],
      commandFailure: operation == "tracking" ? "host:track-devices-l" : "localabstract:test"
    )
    let client = ADBClient(discoveryTimeout: .seconds(2)) { connection }
    do {
      switch operation {
      case "list": _ = try await client.devicesList()
      case "tracking": _ = try await client.trackDevices()
      case "properties": _ = try await client.getProperties(deviceID: "phone")
      case "process":
        #expect(await DeviceDiscovery.processName(deviceID: "phone", using: client, pid: 42) == nil)
      case "user":
        #expect(await DeviceDiscovery.androidUserID(deviceID: "phone", using: client, pid: 42) == nil)
      default: _ = try await client.openLocalAbstract(deviceID: "phone", abstractSocket: "test")
      }
      if operation != "process", operation != "user" { Issue.record("Expected timeout") }
    } catch ADBError.requestTimedOut {}
    #expect(connection.timeouts.first == .seconds(2))
    #expect(connection.isClosed)
  }

  @Test(arguments: [0, -1])
  func rejectsInvalidProcessIDWithoutConnecting(pid: Int) async {
    let client = ADBClient(discoveryTimeout: .seconds(2)) {
      Issue.record("Invalid PID must not open a connection")
      throw CancellationError()
    }
    #expect(await DeviceDiscovery.processName(deviceID: "phone", using: client, pid: pid) == nil)
    #expect(await DeviceDiscovery.androidUserID(deviceID: "phone", using: client, pid: pid) == nil)
  }

  @Test
  func readsProcessMetadata() async {
    let connection = ScriptedADBConnection(reads: [.data(Data("com.example.demo:worker\0ignored".utf8)), .end])
    let client = ADBClient(discoveryTimeout: .seconds(2)) { connection }
    #expect(await DeviceDiscovery.processName(deviceID: "phone", using: client, pid: 321) == "com.example.demo:worker")
    #expect(connection.commands.last == "shell:cat /proc/321/cmdline 2>/dev/null")
  }

  @Test
  func readsProcessUser() async {
    let status = "Name:\tdemo\nUid:\t1010042\t1010042\t1010042\t1010042\n"
    let connection = ScriptedADBConnection(reads: [.data(Data(status.utf8)), .end])
    let client = ADBClient(discoveryTimeout: .seconds(2)) { connection }
    #expect(await DeviceDiscovery.androidUserID(deviceID: "phone", using: client, pid: 321) == 10)
    #expect(connection.commands.last == "shell:cat /proc/321/status 2>/dev/null")
  }

  @Test
  func joinsResponseChunks() async throws {
    let connection = ScriptedADBConnection(reads: [.data(Data("first".utf8)), .data(Data("second".utf8)), .end])
    let client = ADBClient(discoveryTimeout: .seconds(2)) { connection }
    #expect(try await client.listUnixSockets(deviceID: "phone") == "firstsecond")
  }

  @Test(arguments: [false, true])
  func legacyProbeReadsIdentity(http: Bool) async throws {
    let body = http
      ? #"{"protocolVersion":5,"packageName":"com.example.demo","name":"Demo"}"#
      : #"{"method":"SnapO.appInfo","params":{"protocolVersion":1,"packageName":"com.example.demo","processName":"com.example.demo","pid":42}}"#
    let response = http ? "HTTP/1.1 200 OK\r\nContent-Length: \(body.utf8.count)\r\n\r\n" + body : body + "\n"
    let connection = ScriptedADBConnection(reads: [.data(Data(response.utf8)), .end])
    let client = ADBClient(discoveryTimeout: .seconds(2)) { connection }
    let kind = http ? "tweaks" : "network"
    let metadata = try await client.legacyPluginMetadata(
      deviceID: "phone", socketName: "snapo_\(kind)_42",
      kind: ToolID(rawValue: kind), pid: 42
    )
    #expect(metadata?.protocolVersion == (http ? 5 : 1))
    #expect(metadata?.packageName == "com.example.demo")
    #expect(connection.isClosed)
  }

  @Test
  func legacyTimeoutDoesNotStartAnotherProbe() async throws {
    let connection = ScriptedADBConnection(reads: [.data(Data("incomplete".utf8)), .failure(ADBError.requestTimedOut("Synthetic timeout"))])
    let attempts = TestValueCounter()
    let client = ADBClient(discoveryTimeout: .seconds(2)) { attempts.increment()
      return connection
    }
    let metadata = try await client.legacyPluginMetadata(
      deviceID: "phone", socketName: "snapo_network_42", kind: ToolID(rawValue: "network"), pid: 42
    )
    #expect(metadata == nil)
    #expect(attempts.value == 1)
    #expect(connection.timeouts.first == .seconds(2))
    #expect(connection.isClosed)
  }

  @Test
  func cancellingLegacyProbeClosesConnection() async throws {
    let connection = ScriptedADBConnection(reads: [.waitForClose])
    defer { connection.close() }
    let client = ADBClient(discoveryTimeout: .seconds(2)) { connection }
    let task = Task {
      try await client.legacyPluginMetadata(
        deviceID: "phone", socketName: "snapo_network_42", kind: ToolID(rawValue: "network"), pid: 42
      )
    }
    defer { task.cancel() }
    try await connection.waitUntilBlocked()
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(connection.isClosed)
  }

  @Test
  func expiredReadDeadlineFailsWithoutSocketIO() async throws {
    let clock = TestClock()
    let deadline = clock.now.advanced(by: .seconds(2))
    #expect(try ADBSocketConnection.readTimeout(deadline: deadline, clock: clock) == 2001)
    await clock.advance(by: .seconds(2))
    #expect(throws: ADBError.self) { try ADBSocketConnection.readTimeout(deadline: deadline, clock: clock) }
  }
}

private final class TestValueCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0
  var value: Int {
    lock.withLock { count }
  }

  func increment() {
    lock.withLock { count += 1 }
  }
}
