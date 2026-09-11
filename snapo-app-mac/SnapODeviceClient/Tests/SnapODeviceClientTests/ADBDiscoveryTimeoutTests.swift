import Darwin
import Foundation
@testable import SnapODeviceClient
import Testing

@Suite("ADB discovery timeouts")
struct ADBDiscoveryTimeoutTests {
  @Test("a stalled device cannot hide healthy inspectors", arguments: FakeDiscoveryADB.Stall.allCases)
  private func discoversHealthyDevice(stall: FakeDiscoveryADB.Stall) async {
    let server = FakeDiscoveryADB(stall: stall)
    defer { server.close() }
    let adb = server.client()
    let start = ContinuousClock.now
    let sockets = await InspectorDiscovery.discover(
      on: ["stalled", "phone"],
      using: adb,
      definitions: ["network", "tweaks"].map { InspectorSocketDefinition(id: InspectorID(rawValue: $0), socketPrefix: "snapo_\($0)_") }
    )
    #expect(sockets.map(\.reference.deviceId) == ["phone", "phone"])
    #expect(sockets.map(\.kind.rawValue) == ["network", "tweaks"])
    #expect(sockets.allSatisfy { $0.processName == "com.example.demo" })
    #expect(start.duration(to: .now) < .seconds(2))
    #expect(server.connectionCount == 2)

    let recovered = await InspectorDiscovery.discover(
      on: ["phone"],
      using: adb,
      definitions: ["network", "tweaks"].map { InspectorSocketDefinition(id: InspectorID(rawValue: $0), socketPrefix: "snapo_\($0)_") }
    )
    #expect(recovered == sockets)
  }

  @Test("cancelling discovery interrupts a blocked read")
  func cancelsBlockedRead() async throws {
    let server = FakeDiscoveryADB(stall: .output)
    defer { server.close() }
    let task = Task {
      try await server.client(timeout: .seconds(10)).listUnixSockets(deviceID: "stalled")
    }
    var requests = server.requests.stream.makeAsyncIterator()
    _ = await requests.next()
    let start = ContinuousClock.now
    task.cancel()
    do {
      _ = try await task.value
      Issue.record("Expected cancellation")
    } catch is CancellationError {}
    #expect(start.duration(to: .now) < .seconds(1))
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
    let reference = InspectorServerReference(deviceId: "stalled", socketName: "snapo_network_42")
    #expect(await DeviceDiscovery.processName(deviceID: reference.deviceId, using: adb, pid: 42) == nil)
    #expect(await DeviceDiscovery.androidUserID(deviceID: reference.deviceId, using: adb, pid: 42) == nil)
    #expect(server.connectionCount == 3)
  }

  @Test("process metadata uses the explicit PID without an inspector socket")
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

  @Test("port forward setup and cleanup time out without retrying")
  func boundsPortForwarding() async throws {
    let server = FakeDiscoveryADB(stall: .transport)
    defer { server.close() }
    let adb = server.client()
    do {
      _ = try await adb.forwardLocalAbstract(deviceID: "stalled", abstractSocket: "snapo_tweaks_42")
      Issue.record("Expected port forwarding to time out")
    } catch ADBError.requestTimedOut {}
    let forward = try await adb.forwardLocalAbstract(deviceID: "cleanup", abstractSocket: "snapo_tweaks_42")
    await adb.removeForward(forward)
    #expect(server.connectionCount == 3)
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

  let requests = AsyncStream<String>.makeStream()
  private let stall: Stall
  private let workers = DispatchGroup()
  private let lock = NSLock()
  private var peers: [ADBSocketConnection] = []

  init(stall: Stall) {
    self.stall = stall
  }

  var connectionCount: Int {
    lock.withLock { peers.count }
  }

  func client(timeout: Duration = .milliseconds(100)) -> ADBClient {
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
    lock.withLock { peers.append(peer) }
    workers.enter()
    DispatchQueue.global().async { [stall, workers, requests] in
      defer { workers.leave() }
      do {
        try peer.withRequestTimeout(.seconds(2)) {
          let transport = try Self.readRequest(peer)
          if transport.hasPrefix("host-serial:stalled:") { return }
          if transport.hasPrefix("host-serial:cleanup:") {
            if transport.contains(":forward:") { Self.send("OKAY", to: descriptor) }
            return
          }
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
          if stalled {
            if stall == .partialOutput { Self.send("1: 00000002 00000000 00010000 0001 01 101 @snapo_network_99\n", to: descriptor) }
            if stall == .trickle {
              for _ in 0 ..< 50 {
                if !Self.send("x", to: descriptor) { break }
                Thread.sleep(forTimeInterval: 0.01)
              }
              peer.close()
            }
            return
          }
          switch command {
          case "shell:" + InspectorDiscovery.snapshotCommand:
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
