import Darwin
import Foundation
@testable import Snap_O
import Testing

@Suite("ADB discovery timeouts")
struct ADBDiscoveryTimeoutTests {
  /// Continuous output is tested separately because it has no total response deadline.
  @Test(
    "a stalled device cannot hide healthy tools",
    .timeLimit(.minutes(1)),
    arguments: FakeDiscoveryADB.Stall.allCases.filter { $0 != .trickle }
  )
  private func discoversHealthyDevice(stall: FakeDiscoveryADB.Stall) async throws {
    let server = FakeDiscoveryADB(stall: stall)
    defer { server.close() }
    let adb = server.client()
    let sockets = try await ToolDiscovery.discover(
      on: ["stalled", "phone"],
      using: adb
    )
    #expect(sockets.map(\.reference.deviceId) == ["phone", "phone"])
    #expect(sockets.map(\.kind.rawValue) == ["network", "tweaks"])
    #expect(sockets.allSatisfy { $0.processName == "com.example.demo" })
    #expect(server.connectionCount == 2)

    let recovered = try await ToolDiscovery.discover(
      on: ["phone"],
      using: adb
    )
    #expect(recovered == sockets)
  }

  @Test("a failed scan is not an empty result")
  func reportsFailedScan() async throws {
    let server = FakeDiscoveryADB(stall: .output)
    defer { server.close() }
    await #expect(throws: ADBError.self) {
      try await ToolDiscovery.discover(on: ["stalled"], using: server.client())
    }
    let empty = try await ToolDiscovery.discover(on: [], using: server.client())
    #expect(empty.isEmpty)
  }

  @Test("cancelling discovery interrupts a blocked read", arguments: [false, true])
  func cancelsBlockedRead(bootReadiness: Bool) async throws {
    let server = FakeDiscoveryADB(stall: .output)
    defer { server.close() }
    let task = Task {
      let adb = server.client(timeout: .seconds(10))
      if bootReadiness {
        _ = try await adb.isBootComplete(deviceID: "stalled")
      } else {
        _ = try await adb.listUnixSockets(deviceID: "stalled")
      }
    }
    var requests = server.requests.stream.makeAsyncIterator()
    _ = await requests.next()
    task.cancel()
    server.expectClosedConnections()
    do {
      _ = try await task.value
      Issue.record("Expected cancellation")
    } catch is CancellationError {}
    #expect(server.connectionCount == 1)
  }

  @Test("cancelling device tracking interrupts the initial ADB reply")
  func cancelsTrackingHandshake() async throws {
    let server = FakeDiscoveryADB(stall: .transport)
    defer { server.close() }
    let rescue = Task {
      try await Task.sleep(for: .seconds(30))
      Issue.record("Handshake did not reach the cancellation point")
      server.close()
    }
    defer { rescue.cancel() }
    let task = Task {
      let (handle, _) = try await server.client(timeout: .seconds(10)).trackDevices()
      handle.cancel()
    }
    var requests = server.requests.stream.makeAsyncIterator()
    #expect(await requests.next() == "host:track-devices-l")
    task.cancel()
    server.expectClosedConnections()
    do {
      try await task.value
      Issue.record("Expected cancellation")
    } catch is CancellationError {
      // Cancellation must interrupt the socket read, without waiting for its timeout.
    } catch {
      Issue.record("Expected cancellation, got \(error)")
    }
    #expect(server.connectionCount == 1)
  }

  @Test("device tracking bounds its initial ADB reply")
  func boundsTrackingHandshake() async throws {
    let server = FakeDiscoveryADB(stall: .transport)
    defer { server.close() }
    let rescue = Task {
      // The expected timeout is 500 ms; this only prevents a broken test from hanging.
      try await Task.sleep(for: .seconds(10))
      server.close()
    }
    defer { rescue.cancel() }
    do {
      let (handle, _) = try await server.client().trackDevices()
      handle.cancel()
      Issue.record("Expected tracking setup to time out")
    } catch ADBError.requestTimedOut {
      // A setup timeout must not restart the ADB connection.
    } catch {
      Issue.record("Expected timeout, got \(error)")
    }
    #expect(server.connectionCount == 1)
  }

  @Test("idle device tracking remains open and cancels promptly")
  func cancelsIdleTracking() async throws {
    let server = FakeDiscoveryADB(stall: .output)
    defer { server.close() }
    let (handle, stream) = try await server.client().trackDevices()
    defer { handle.cancel() }
    let received = AsyncStream<Void>.makeStream()
    let task = Task {
      for try await _ in stream {
        received.continuation.yield(())
      }
      return Task.isCancelled
    }
    var snapshots = received.stream.makeAsyncIterator()
    _ = await snapshots.next()
    // An unchanged device list can stay silent longer than the setup timeout.
    try await Task.sleep(for: .milliseconds(700))
    task.cancel()
    server.expectClosedConnections()
    #expect(try await task.value)
    #expect(server.connectionCount == 1)
  }

  @Test("connection setup deadlines do not limit subsequent streaming")
  func restoresStreamingReads() throws {
    var descriptors: [Int32] = [0, 0]
    try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0)
    let connection = ADBSocketConnection(connectedSocket: descriptors[0])
    let peer = ADBSocketConnection(connectedSocket: descriptors[1])
    defer {
      connection.close()
      peer.close()
    }
    do {
      _ = try connection.withRequestTimeout(.milliseconds(5)) { try connection.readLine() }
      Issue.record("Expected an idle socket to time out")
    } catch ADBError.requestTimedOut {}
    let writer = DispatchGroup()
    writer.enter()
    DispatchQueue.global().async {
      defer { writer.leave() }
      Thread.sleep(forTimeInterval: 0.05)
      try? peer.writeLine("record")
    }
    defer { writer.wait() }
    #expect(try connection.readLine() == "record")
  }

  @Test("boot readiness requires Android's completed signal", arguments: ["", "0\n", "1\r\n", "true\n"])
  func readsBootReadiness(output: String) async throws {
    let server = FakeDiscoveryADB(stall: .output, bootOutput: output)
    defer { server.close() }
    let ready = try await server.client().isBootComplete(deviceID: "phone")
    #expect(ready == (output == "1\r\n"))
  }

  @Test("emulator discovery ignores boot results from a reused transport")
  func ignoresBootResultAfterTransportReuse() async throws {
    let server = FakeDiscoveryADB(stall: .output, deviceLists: [
      "emulator-5554 device transport_id:2\n",
      "emulator-5554 device transport_id:4\n"
    ])
    defer { server.close() }
    let connections = try await server.client().emulatorConnections()
    #expect(connections.first?.state == .starting)
  }

  @Test("device list requests time out")
  func boundsDeviceList() async throws {
    let server = FakeDiscoveryADB(stall: .transport)
    defer { server.close() }
    do {
      _ = try await server.client().devicesList()
      Issue.record("Expected device list timeout")
    } catch ADBError.requestTimedOut {}
  }

  @Test("device properties and process metadata have bounded requests")
  func boundsMetadata() async throws {
    let server = FakeDiscoveryADB(stall: .output)
    defer { server.close() }
    let adb = server.client()
    do {
      _ = try await adb.getProperties(deviceID: "stalled")
      Issue.record("Expected property request to time out")
    } catch ADBError.requestTimedOut {
      // A device timeout must not trigger the ADB server retry path.
    }
    do {
      _ = try await adb.isBootComplete(deviceID: "stalled")
      Issue.record("Expected boot readiness request to time out")
    } catch ADBError.requestTimedOut {}
    let reference = ToolServerReference(deviceId: "stalled", socketName: "snapo_network_42")
    #expect(await DeviceDiscovery.processName(deviceID: reference.deviceId, using: adb, pid: 42) == nil)
    #expect(await DeviceDiscovery.androidUserID(deviceID: reference.deviceId, using: adb, pid: 42) == nil)
    #expect(server.connectionCount == 4)
  }

  @Test("process metadata uses the explicit PID without a tool socket")
  func readsProcessMetadata() async {
    let server = FakeDiscoveryADB(stall: .output)
    defer { server.close() }
    let adb = server.client()
    #expect(await DeviceDiscovery.processName(deviceID: "phone", using: adb, pid: 321) == "com.example.demo:worker")
    #expect(await DeviceDiscovery.androidUserID(deviceID: "phone", using: adb, pid: 321) == 10)
    #expect(server.connectionCount == 2)
  }

  @Test("invalid process IDs do not issue ADB requests", arguments: [0, -1])
  func rejectsInvalidProcessID(pid: Int) async {
    let server = FakeDiscoveryADB(stall: .output)
    defer { server.close() }
    let adb = server.client()
    #expect(await DeviceDiscovery.processName(deviceID: "phone", using: adb, pid: pid) == nil)
    #expect(await DeviceDiscovery.androidUserID(deviceID: "phone", using: adb, pid: pid) == nil)
    #expect(server.connectionCount == 0)
  }

  @Test("direct socket setup times out without retrying")
  func boundsDirectSocketSetup() async throws {
    let server = FakeDiscoveryADB(stall: .transport)
    defer { server.close() }
    let adb = server.client()
    do {
      _ = try await adb.openLocalAbstract(deviceID: "stalled", abstractSocket: "snapo_tweaks_42")
      Issue.record("Expected direct socket setup to time out")
    } catch ADBError.requestTimedOut {}
    let connection = try await adb.openLocalAbstract(deviceID: "phone", abstractSocket: "snapo_tweaks_42")
    connection.close()
    #expect(server.connectionCount == 2)
  }

  @Test("legacy probes read identity without starting inspection")
  func readsLegacyIdentity() async throws {
    let raw = #"{"method":"SnapO.appInfo","params":{"protocolVersion":1,"packageName":"com.example.demo","processName":"com.example.demo","pid":42}}"#
    let http = #"{"protocolVersion":5,"packageName":"com.example.demo","name":"Demo"}"#
    for (reply, kind, expectedVersion) in [
      (FakeDiscoveryADB.LegacyReply.raw(raw), "network", 1), (.http(http), "tweaks", 5)
    ] {
      let server = FakeDiscoveryADB(stall: .output, legacyReply: reply)
      defer { server.close() }
      let metadata = try await server.client().legacyPluginMetadata(
        reference: ToolServerReference(deviceId: "phone", socketName: "snapo_\(kind)_42"), kind: ToolID(rawValue: kind),
        pid: 42
      )
      #expect(metadata?.protocolVersion == expectedVersion)
      #expect(metadata?.packageName == "com.example.demo")
      #expect(server.connectionCount == 1)
    }
  }

  @Test("legacy probes have a total read deadline even when bytes keep arriving")
  func boundsLegacyTrickle() async throws {
    let server = FakeDiscoveryADB(stall: .output, legacyReply: .trickle)
    defer { server.close() }
    let metadata = try await server.client().legacyPluginMetadata(
      reference: ToolServerReference(deviceId: "phone", socketName: "snapo_network_42"), kind: ToolID(rawValue: "network"),
      pid: 42
    )
    #expect(metadata == nil)
    #expect(!server.legacyStreamFinished)
    #expect(server.connectionCount == 1)
  }

  @Test("cancelling a legacy probe closes the socket without trying a fallback")
  func cancelsLegacyProbe() async throws {
    let server = FakeDiscoveryADB(stall: .output, legacyReply: .trickle)
    defer { server.close() }
    let task = Task {
      try await server.client().legacyPluginMetadata(
        reference: ToolServerReference(deviceId: "phone", socketName: "snapo_network_42"), kind: ToolID(rawValue: "network"),
        pid: 42
      )
    }
    var requests = server.requests.stream.makeAsyncIterator()
    _ = await requests.next()
    task.cancel()
    server.expectClosedConnections()
    do {
      _ = try await task.value
      Issue.record("Expected cancellation")
    } catch is CancellationError {}
    #expect(server.connectionCount == 1)
  }

  @Test("native timeouts allow output that continues making progress")
  func allowsContinuousOutput() async throws {
    let server = FakeDiscoveryADB(stall: .trickle)
    defer { server.close() }
    let output = try await server.client().listUnixSockets(deviceID: "stalled")
    #expect(output == String(repeating: "x", count: 50))
  }
}

private final class FakeDiscoveryADB: @unchecked Sendable {
  enum Stall: CaseIterable {
    case transport, shell, output, partialStatus, partialOutput, trickle
  }

  enum LegacyReply {
    case raw(String), http(String), trickle
  }

  private let legacyReply: LegacyReply?
  private let bootOutput: String
  private let deviceLists: [String]
  private var listRequests = 0
  let requests = AsyncStream<String>.makeStream()
  private let stall: Stall
  private let workers = DispatchGroup()
  private let lock = NSLock()
  private var peers: [ADBSocketConnection] = []
  private var connections: [ADBSocketConnection] = []
  private var finishedLegacyStream = false

  init(stall: Stall, legacyReply: LegacyReply? = nil, bootOutput: String = "1\n", deviceLists: [String] = []) {
    self.stall = stall
    self.legacyReply = legacyReply
    self.bootOutput = bootOutput
    self.deviceLists = deviceLists
  }

  var connectionCount: Int {
    lock.withLock { peers.count }
  }

  var legacyStreamFinished: Bool {
    lock.withLock { finishedLegacyStream }
  }

  func expectClosedConnections() {
    let active = lock.withLock { connections }
    #expect(!active.isEmpty)
    active.forEach { expectClosedConnection($0) }
  }

  func client(timeout: Duration = .milliseconds(500)) -> ADBClient {
    // Leave room for worker scheduling on shared CI runners.
    ADBClient(discoveryTimeout: timeout) { try self.connect() }
  }

  func close() {
    workers.wait()
    lock.withLock { peers.forEach { $0.close() } }
  }

  private func connect() throws -> ADBSocketConnection {
    var descriptors: [Int32] = [0, 0]
    guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
      throw POSIXError(.EIO)
    }
    let connection = ADBSocketConnection(connectedSocket: descriptors[0])
    let peer = ADBSocketConnection(connectedSocket: descriptors[1])
    let descriptor = descriptors[1]
    var noSigPipe: Int32 = 1
    _ = setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
    lock.withLock {
      peers.append(peer)
      connections.append(connection)
    }
    workers.enter()
    DispatchQueue.global().async { [stall, workers, requests, legacyReply, bootOutput] in
      defer { workers.leave() }
      do {
        try peer.withRequestTimeout(.seconds(2)) {
          let transport = try Self.readRequest(peer)
          if transport == "host:devices-l" {
            if stall == .transport { return }
            let payload = self.lock.withLock {
              let payload = self.deviceLists.indices.contains(self.listRequests) ? self.deviceLists[self.listRequests] : ""
              self.listRequests += 1
              return payload
            }
            Self.send("OKAY" + String(format: "%04X", payload.utf8.count) + payload, to: descriptor)
            peer.close()
            return
          }
          if transport == "host:track-devices-l" {
            if stall != .transport { Self.send("OKAY0000", to: descriptor) }
            requests.continuation.yield(transport)
            return
          }
          if transport.hasPrefix("host-serial:stalled:") { return }
          let stalled = transport == "host:transport:stalled"
          if stalled, stall == .transport { return }
          if stalled, stall == .partialStatus {
            Self.send("OK", to: descriptor)
            return
          }
          Self.send("OKAY", to: descriptor)
          let command = try Self.readRequest(peer)
          requests.continuation.yield(command)
          if stalled, stall == .shell { return }
          Self.send("OKAY", to: descriptor)
          if command.hasPrefix("localabstract:"), let legacyReply {
            defer { peer.close() }
            guard let request = try peer.readLine() else { return }
            switch legacyReply {
            case .raw(let response):
              guard request == "HelloSnapO" else { return }
              Self.send(response + "\n", to: descriptor)
            case .http(let body):
              guard request == "GET /app HTTP/1.1" else { return }
              while let header = try peer.readLine(), !header.isEmpty {}
              Self.send("HTTP/1.1 200 OK\r\nContent-Length: \(body.utf8.count)\r\n\r\n" + body, to: descriptor)
            case .trickle:
              for _ in 0 ..< 200 {
                if !Self.send("x", to: descriptor) { return }
                Thread.sleep(forTimeInterval: 0.03)
              }
              self.lock.withLock { self.finishedLegacyStream = true }
            }
            return
          }
          if stalled {
            if stall == .partialOutput { Self.send("1: 00000002 00000000 00010000 0001 01 101 @snapo_network_99\n", to: descriptor) }
            if stall == .trickle {
              for _ in 0 ..< 50 {
                if !Self.send("x", to: descriptor) { break }
                // Keep the full stream longer than the client's idle timeout.
                Thread.sleep(forTimeInterval: 0.03)
              }
              peer.close()
            }
            return
          }
          switch command {
          case "shell:getprop sys.boot_completed":
            Self.send(bootOutput, to: descriptor)
          case "shell:" + ToolDiscovery.snapshotCommand:
            Self.send(
              "1: 00000002 00000000 00010000 0001 01 101 @snapo_network_42\n2: 00000002 00000000 00010000 0001 01 101 @snapo_tweaks_42\n\n---snapo-processes---\nPID NAME\n42 com.example.demo\n",
              to: descriptor
            )
          case "shell:cat /proc/321/cmdline 2>/dev/null":
            Self.send("com.example.demo:worker\0ignored", to: descriptor)
          case "shell:cat /proc/321/status 2>/dev/null":
            Self.send("Uid: 1010234 1010234 1010234 1010234\n", to: descriptor)
          default:
            Self.send(
              "1: 00000002 00000000 00010000 0001 01 101 @snapo_network_42\n2: 00000002 00000000 00010000 0001 01 101 @snapo_tweaks_42\n",
              to: descriptor
            )
          }
          peer.close()
        }
      } catch {
        peer.close()
      }
    }
    return connection
  }

  private static func readRequest(_ peer: ADBSocketConnection) throws -> String {
    func read(_ count: Int) throws -> Data {
      var data = Data()
      while data.count < count {
        guard let chunk = try peer.readChunk(maxLength: count - data.count) else {
          throw ADBError.protocolFailure("Test peer closed")
        }
        data.append(chunk)
      }
      return data
    }
    let header = try read(4)
    guard let text = String(data: header, encoding: .ascii), let count = Int(text, radix: 16) else {
      throw ADBError.protocolFailure("Invalid test request")
    }
    guard let request = try String(bytes: read(count), encoding: .utf8) else {
      throw ADBError.protocolFailure("Invalid test request encoding")
    }
    return request
  }

  @discardableResult
  private static func send(_ text: String, to descriptor: Int32) -> Bool {
    let data = Data(text.utf8)
    return data.withUnsafeBytes { Darwin.send(descriptor, $0.baseAddress, $0.count, 0) == $0.count }
  }
}
