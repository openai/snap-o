import Clocks
import Dependencies
import DependenciesTestSupport
import Foundation
import Testing

@Suite("Remote ADB", .dependency(\.continuousClock, TestClock()))
struct RemoteADBTests {
  private let serverID = ADBServerID.remote(UUID())

  @Test
  func identitySeparatesServersAndPreservesLocalKeys() {
    let local = DeviceID(serverID: .local, serial: "emulator-5554")
    let remote = DeviceID(serverID: serverID, serial: local.serial)
    #expect(local.storedValue == local.serial)
    #expect(remote.storedValue != local.storedValue)
    #expect(DeviceID(storedValue: remote.storedValue) == remote)
    #expect(local.isLocalEmulator)
    #expect(!remote.isLocalEmulator)
    let reserved = DeviceID(serverID: .local, serial: remote.storedValue)
    #expect(reserved.storedValue != remote.storedValue)
    #expect(DeviceID(storedValue: reserved.storedValue) == reserved)
  }

  @Test
  func boundClientUsesTargetsServerAndInvalidationClosesSocket() async throws {
    let local = ScriptedADBConnection()
    let remote = ScriptedADBConnection()
    let server = Server(id: serverID, connection: remote)
    let target = DeviceTarget(serial: "same-serial", transportID: "1", server: server)
    let unbound = ADBClient(discoveryTimeout: .seconds(1)) { local }
    let client = unbound.bound(to: target)
    let socket = try await client.makeConnection(maxAttempts: 1)
    #expect(socket as? ScriptedADBConnection === remote)
    try socket.sendTransport(to: "same-serial")
    #expect(remote.commands == ["host:transport-id:1"])
    #expect(local.commands.isEmpty)
    target.invalidate()
    #expect(remote.isClosed)
    await #expect(throws: (any Error).self) { try await client.makeConnection(maxAttempts: 1) }
  }

  @Test
  func closedServerRejectsNewSockets() throws {
    let tracking = ScriptedADBConnection()
    let session = ADBServerSession(tracking: tracking, timeout: .seconds(1), serverID: serverID) {
      Issue.record("A closed session must not use its old endpoint")
      return ScriptedADBConnection()
    }
    let target = DeviceTarget(serial: "phone", transportID: "1", server: session)
    session.close()
    #expect(!target.isValid)
    #expect(throws: (any Error).self) { try session.makeOperationConnection() }
  }

  @Test
  func inventoryDoesNotWaitForRemoteAndIsolatesRemoteLoss() async {
    let local = Tracker()
    let remote = Tracker()
    let service = ADBService(trackers: [(.local, local), (serverID, remote)])
    let localDevice = device(serverID: .local)
    let remoteDevice = device(serverID: serverID)
    var iterator = await service.previewDeviceStream().makeAsyncIterator()
    await service.startTracking()
    await local.publish([localDevice])
    let initial = await iterator.next()
    #expect(initial?.map(\.id) == [localDevice.id])
    await remote.publish([remoteDevice])
    let combined = await iterator.next()
    #expect(Set(combined?.map(\.id) ?? []) == [localDevice.id, remoteDevice.id])
    await remote.publish([])
    let remaining = await iterator.next()
    #expect(remaining?.map(\.id) == [localDevice.id])
    await service.stopTracking()
    #expect(await local.stopped)
    #expect(await remote.stopped)
    #expect(await iterator.next() == nil)
  }

  @MainActor
  @Test
  func lateTunnelReplyIsClosedAfterCancellation() async throws {
    let started = TestValue(false)
    let reply = AsyncStream<ADBTunnelHandle>.makeStream()
    let closed = TestValue([String]())
    let finished = TestValue(false)
    let owner = ADBServerConnection(
      configuration: RemoteADBServer(id: UUID(), ssh: SSHConfiguration(destination: "test-host")),
      openTunnel: { id, _ in
        started.value = true
        // Deliberately ignore cancellation like a late XPC reply.
        return await Task.detached {
          var replies = reply.stream.makeAsyncIterator()
          return await replies.next() ?? ADBTunnelHandle(id: id)
        }.value
      },
      socketFactory: { _ in { throw CancellationError() } },
      closeTunnel: { closed.value.append($0) },
      disconnect: { finished.value = true }
    )
    let opening = Task { try await owner.client() }
    try await waitForState { started.value }
    let stopping = Task { await owner.close() }
    try await waitForState { !closed.value.isEmpty }
    #expect(!finished.value)
    reply.continuation.yield(ADBTunnelHandle(id: closed.value[0]))
    reply.continuation.finish()
    await stopping.value
    await #expect(throws: (any Error).self) { try await opening.value }
    #expect(finished.value)
    #expect(Set(closed.value).count == 1)
  }

  @MainActor
  @Test
  func serialLinksRejectAmbiguityAndExplicitLinksResolve() async throws {
    let local = DeviceID(serverID: .local, serial: "emulator-5554")
    let remote = DeviceID(serverID: serverID, serial: local.serial)
    let resolver = DeviceOpenResolver(snapshot: {
      DeviceOpenSnapshot(connectedSerials: [local.storedValue, remote.storedValue])
    }, start: { _ in Issue.record("Resolving a remote device must not launch a local emulator") })
    await #expect(throws: DeviceOpenError.self) { try await resolver.resolve(.serial(local.serial)) { _ in } }
    let result = try await resolver.resolve(.device(remote)) { _ in }
    #expect(result == remote.storedValue)
    let request = DeviceOpenRequest.device(remote)
    #expect(request.url.flatMap(DeviceOpenRequest.init(url:)) == request)
    let localRequest = DeviceOpenRequest.device(local)
    #expect(localRequest.url.flatMap(DeviceOpenRequest.init(url:)) == localRequest)
  }

  @Test
  func remoteRetriesUseBackoffAndStopCancelsTheTimer() async throws {
    @Dependency(\.continuousClock, as: TestClock<Duration>.self)
    var clock
    let attempts = Counter()
    let tracker = DeviceTracker(connect: {
      await attempts.increment()
      throw ADBError.serverUnavailable("Synthetic outage")
    }, retriesWithBackoff: true)
    await tracker.startTracking()
    await attempts.wait(for: 1)
    await clock.advance(by: .seconds(1))
    await attempts.wait(for: 2)
    await clock.advance(by: .seconds(1))
    #expect(await attempts.value == 2)
    await clock.advance(by: .seconds(1))
    await attempts.wait(for: 3)
    await tracker.stopTracking()
    await clock.advance(by: .seconds(30))
    #expect(await attempts.value == 3)
    try await clock.checkSuspension()
  }

  private actor Counter {
    var value = 0
    let changed = TestSignal()
    func increment() {
      value += 1
      changed.signal()
    }

    func wait(for expected: Int) async {
      while value < expected {
        let revision = changed.revision
        if value < expected { try? await changed.wait(after: revision) }
      }
    }
  }

  private func device(serverID: ADBServerID) -> Device {
    let target = DeviceTarget(serial: "emulator-5554", transportID: "1", server: Server(id: serverID, connection: ScriptedADBConnection()))
    return Device(
      id: target.serial,
      model: "Test",
      androidVersion: "13",
      vendorModel: nil,
      manufacturer: nil,
      avdName: nil,
      connection: target
    )
  }

  private final class Server: DeviceServerConnection, @unchecked Sendable {
    let id = UUID()
    let serverID: ADBServerID
    let connection: ScriptedADBConnection
    init(id: ADBServerID, connection: ScriptedADBConnection) {
      serverID = id
      self.connection = connection
    }

    func register(_: DeviceTarget) {}
    func verifyConnection(selecting: () throws -> Void) throws {
      try selecting()
    }

    func makeOperationConnection() throws -> any ADBConnection {
      connection
    }
  }

  private actor Tracker: DeviceTracking {
    let connected = AsyncStream<[Device]>.makeStream()
    let ready = AsyncStream<[Device]>.makeStream()
    let state = AsyncStream<ADBServerState>.makeStream()
    var stopped = false
    func startTracking() {}
    func retryADBServer() {}
    func previewDeviceStream() -> AsyncStream<[Device]> {
      connected.stream
    }

    func deviceStream() -> AsyncStream<[Device]> {
      ready.stream
    }

    func serverStateStream() -> AsyncStream<ADBServerState> {
      state.stream
    }

    func publish(_ devices: [Device]) {
      connected.continuation.yield(devices)
    }

    func stopTracking() {
      stopped = true
      connected.continuation.finish()
      ready.continuation.finish()
      state.continuation.finish()
    }
  }
}
