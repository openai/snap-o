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

  @Test(arguments: [false, true])
  func legacyMetadataUsesRemoteTransportAndRawSerial(http: Bool) async throws {
    let body = http
      ? #"{"protocolVersion":5,"packageName":"com.example.demo","name":"Demo"}"#
      : #"{"method":"SnapO.appInfo","params":{"protocolVersion":1,"packageName":"com.example.demo",""#
      + #"processName":"com.example.demo","pid":42}}"#
    let response = http ? "HTTP/1.1 200 OK\r\nContent-Length: \(body.utf8.count)\r\n\r\n" + body : body + "\n"
    let local = ScriptedADBConnection()
    let remote = ScriptedADBConnection(reads: [.data(Data(response.utf8)), .end])
    let server = Server(id: serverID, connection: remote)
    let target = DeviceTarget(serial: "emulator-5554", transportID: "7", server: server)
    let client = ADBClient(discoveryTimeout: .seconds(2)) { local }.bound(to: target)
    let kind: ToolID = http ? .tweaks : .network
    let reference = ToolServerReference(deviceId: target.deviceID.storedValue, socketName: "snapo_\(kind.rawValue)_42")
    #expect(reference.deviceId != target.serial)
    let metadata = try await client.legacyPluginMetadata(
      deviceID: target.serial, socketName: reference.socketName, kind: kind, pid: 42
    )
    #expect(metadata?.packageName == "com.example.demo")
    #expect(metadata?.protocolVersion == (http ? 5 : 1))
    #expect(remote.commands == ["host:transport-id:7", "localabstract:" + reference.socketName])
    #expect(String(data: remote.written, encoding: .utf8) == LegacyPluginReader.request(kind: kind))
    #expect(remote.isClosed)
    #expect(local.commands.isEmpty)
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

  @Test(arguments: [false, true])
  func initializedInventorySurvivesServerRemovalAndReplacement(replace: Bool) async throws {
    let local = Tracker()
    let old = Tracker()
    let replacement = Tracker()
    let service = ADBService(trackers: [(.local, local), (serverID, old)])
    var preview = await service.previewDeviceStream().makeAsyncIterator()
    var ready = await service.deviceStream().makeAsyncIterator()
    await service.startTracking()
    let original = device(serverID: serverID)
    await old.publish([original])
    #expect(await preview.next() == [original])
    await old.publishReady([original])
    #expect(await ready.next() == [original])

    // Local discovery stays pending while the only initialized server disappears.
    try await service.replaceRemote(serverID, tracker: replace ? replacement : nil)
    #expect(await preview.next() == [])
    #expect(await ready.next() == [])
    var latePreview = await service.previewDeviceStream().makeAsyncIterator()
    var lateReady = await service.deviceStream().makeAsyncIterator()
    #expect(await latePreview.next() == [])
    #expect(await lateReady.next() == [])

    if replace {
      let fresh = device(serverID: serverID)
      await replacement.publish([fresh])
      #expect(await preview.next() == [fresh])
      await replacement.publishReady([fresh])
      #expect(await ready.next() == [fresh])
    }
    await service.stopTracking()
  }

  @Test
  func removingUninitializedServerDoesNotCompleteDiscovery() async throws {
    let service = ADBService(trackers: [(.local, Tracker()), (serverID, Tracker())])
    var preview = await service.previewDeviceStream().makeAsyncIterator()
    var ready = await service.deviceStream().makeAsyncIterator()
    await service.startTracking()
    try await service.replaceRemote(serverID, tracker: nil)
    await service.stopTracking()
    #expect(await preview.next() == nil)
    #expect(await ready.next() == nil)
  }

  @Test
  func previewInitializationDoesNotInitializeReadyInventory() async throws {
    let remote = Tracker()
    let service = ADBService(trackers: [(serverID, remote)])
    var preview = await service.previewDeviceStream().makeAsyncIterator()
    var ready = await service.deviceStream().makeAsyncIterator()
    await service.startTracking()
    let original = device(serverID: serverID)
    await remote.publish([original])
    #expect(await preview.next() == [original])
    try await service.replaceRemote(serverID, tracker: nil)
    #expect(await preview.next() == [])
    var lateReady = await service.deviceStream().makeAsyncIterator()
    await service.stopTracking()
    #expect(await ready.next() == nil)
    #expect(await lateReady.next() == nil)
  }

  @Test
  func readyInventoryDropsDisconnectedTargetsBeforeMetadataCatchesUp() async {
    let remote = Tracker()
    let service = ADBService(trackers: [(serverID, remote)])
    var preview = await service.previewDeviceStream().makeAsyncIterator()
    var ready = await service.deviceStream().makeAsyncIterator()
    await service.startTracking()
    let original = device(serverID: serverID)
    await remote.publish([original])
    #expect(await preview.next() == [original])
    await remote.publishReady([original])
    #expect(await ready.next() == [original])
    await remote.publish([])
    #expect(await ready.next() == [])
    var lateReady = await service.deviceStream().makeAsyncIterator()
    #expect(await lateReady.next() == [])
    await service.stopTracking()
  }

  @Test
  func replacingRemoteKeepsLocalAndRejectsChangesAfterShutdown() async throws {
    let local = Tracker()
    let old = Tracker()
    let replacement = Tracker()
    let service = ADBService(trackers: [(.local, local), (serverID, old)])
    await service.startTracking()
    try await service.replaceRemote(serverID, tracker: replacement)
    #expect(await old.stopped)
    #expect(await local.stopped == false)
    #expect(await replacement.stopped == false)
    try await service.replaceRemote(serverID, tracker: nil)
    #expect(await replacement.stopped)
    #expect(await local.stopped == false)
    await service.stopTracking()
    await #expect(throws: (any Error).self) { try await service.replaceRemote(serverID, tracker: Tracker()) }
    await #expect(throws: (any Error).self) { try await service.replaceRemote(.local, tracker: nil) }
  }

  @Test(arguments: [
    SSHConfiguration(destination: "test-host"),
    SSHConfiguration(destination: "user@test-host", port: 2222, adbPort: 5038)
  ])
  func typedSSHProfilesPreserveIdentityAndSettings(configuration: SSHConfiguration) throws {
    let profile = RemoteADBServer(id: UUID(), connection: .ssh(configuration))
    let encoded = try JSONEncoder().encode(profile)
    let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    let connection = try #require(object["connection"] as? [String: Any])
    #expect(connection["type"] as? String == "ssh")
    #expect(try JSONDecoder().decode(RemoteADBServer.self, from: encoded) == profile)
    #expect(profile.connection.displayAddress == configuration.displayAddress)
  }

  @Test(arguments: [
    #"{"type":"future","ssh":{"destination":"test-host","adbPort":5037}}"#,
    #"{"type":"ssh"}"#,
    "null"
  ])
  func invalidTypedConnectionsAreRejected(connection: String) {
    let data = Data("""
    {"id":"8FA7AA18-BEC2-40AA-89D4-B8709B677D20","connection":\(connection)}
    """.utf8)
    #expect(throws: DecodingError.self) {
      try JSONDecoder().decode(RemoteADBServer.self, from: data)
    }
  }

  @MainActor
  @Test
  func savedServersStartEmptyAndPreserveIdentityPortsAndExplicitEmptyList() throws {
    let name = "snapo-server-tests-" + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let store = ADBServerStore(defaults: defaults)
    #expect(try store.load().isEmpty)
    let profile = RemoteADBServer(id: UUID(), connection: .ssh(SSHConfiguration(destination: "user@test-host", port: 2222, adbPort: 5038)))
    try store.save([profile])
    #expect(try store.load() == [profile])
    #expect(throws: (any Error).self) { try store.save([profile, profile]) }
    #expect(try store.load() == [profile])
    try store.save([])
    #expect(try store.load().isEmpty)
  }

  @MainActor
  @Test
  func editingServersPersistsLabelsAndRejectsDuplicatesAndShutdownChanges() async throws {
    let name = "snapo-server-model-tests-" + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let store = ADBServerStore(defaults: defaults)
    let service = ADBService(trackers: [(.local, Tracker())])
    let labels = TestValue([ADBServerID: String]())
    let makeTracker: (RemoteADBServer) -> any DeviceTracking = { _ in Tracker() }
    let model = ADBServers(service: service, store: store, profiles: [], makeTracker: makeTracker) {
      labels.value = $0
    }
    let profile = RemoteADBServer(id: UUID(), connection: .ssh(SSHConfiguration(destination: "test-host", port: 2222)))
    await service.startTracking()
    try await model.save(profile)
    #expect(try store.load() == [profile])
    #expect(labels.value[.remote(profile.id)] == "test-host (SSH 2222)")
    await #expect(throws: (any Error).self) {
      try await model.save(RemoteADBServer(id: UUID(), connection: profile.connection))
    }
    #expect(model.profiles == [profile])
    try await model.remove(profile)
    #expect(try store.load().isEmpty)
    #expect(labels.value.isEmpty)
    model.beginShutdown()
    await #expect(throws: (any Error).self) { try await model.save(profile) }
    #expect(try store.load().isEmpty)
    await model.stop()
    await service.stopTracking()
  }

  @Test
  func olderSavedServersDefaultToEnabled() throws {
    let data = Data("""
    {"id":"8FA7AA18-BEC2-40AA-89D4-B8709B677D20",
     "connection":{"type":"ssh","ssh":{"destination":"test-host","adbPort":5037}}}
    """.utf8)
    #expect(try JSONDecoder().decode(RemoteADBServer.self, from: data).isEnabled)
  }

  @MainActor
  @Test
  func disconnectPersistsAndEditingStaysDisconnectedUntilReconnect() async throws {
    let name = "snapo-server-toggle-tests-" + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let store = ADBServerStore(defaults: defaults)
    let local = Tracker()
    let remote = Tracker()
    let replacement = Tracker()
    let profile = RemoteADBServer(id: UUID(), connection: .ssh(SSHConfiguration(destination: "test-host")))
    let service = ADBService(trackers: [(.local, local), (.remote(profile.id), remote)])
    var creations = 0
    let model = ADBServers(service: service, store: store, profiles: [profile], makeTracker: { _ in
      creations += 1
      return replacement
    }, updateLabels: { _ in })
    await service.startTracking()
    try await model.setEnabled(false, for: profile)
    #expect(await remote.stopped)
    #expect(await local.stopped == false)
    #expect(creations == 0)
    var disabled = try #require(store.load().first)
    #expect(!disabled.isEnabled)
    #expect(disabled.id == profile.id)
    #expect(model.profiles == [disabled])
    disabled.connection = .ssh(SSHConfiguration(destination: "edited-host"))
    try await model.save(disabled)
    #expect(creations == 0)
    #expect(try store.load() == [disabled])
    var snapshots = await service.snapshots().makeAsyncIterator()
    #expect(await snapshots.next()?.map(\.id) == [.local])
    try await model.setEnabled(true, for: profile)
    #expect(creations == 1)
    let enabled = try #require(store.load().first)
    #expect(enabled.isEnabled)
    #expect(enabled.connection == disabled.connection)
    var reconnected = await service.snapshots().makeAsyncIterator()
    #expect(await reconnected.next()?.map(\.id) == [.local, .remote(profile.id)])
    try await model.setEnabled(true, for: enabled)
    #expect(creations == 1)
    await model.stop()
    await service.stopTracking()
    #expect(await replacement.stopped)
  }

  @MainActor
  @Test
  func disconnectReportsTheUpdatingServerUntilCleanupFinishes() async throws {
    let name = "snapo-server-progress-tests-" + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let cleanup = TestSuspension()
    let remote = Tracker(stopSuspension: cleanup)
    let profile = RemoteADBServer(id: UUID(), connection: .ssh(SSHConfiguration(destination: "test-host")))
    let service = ADBService(trackers: [(.remote(profile.id), remote)])
    let model = ADBServers(
      service: service, store: ADBServerStore(defaults: defaults), profiles: [profile],
      makeTracker: { _ in Tracker() }, updateLabels: { _ in }
    )
    await service.startTracking()
    let disconnect = Task { try await model.setEnabled(false, for: profile) }
    await cleanup.waitUntilStarted()
    #expect(model.updatingServerID == profile.id)
    #expect(model.isUpdating)
    #expect(model.profiles.first?.isEnabled == false)
    cleanup.resume()
    try await disconnect.value
    #expect(model.updatingServerID == nil)
    #expect(!model.isUpdating)
    await model.stop()
    await service.stopTracking()
  }

  @MainActor
  @Test
  func lateTunnelReplyIsClosedAfterCancellation() async throws {
    let started = TestValue(false)
    let reply = AsyncStream<ADBTunnelHandle>.makeStream()
    let closed = TestValue([String]())
    let finished = TestValue(false)
    let owner = ADBServerConnection(
      serverID: UUID(), configuration: SSHConfiguration(destination: "test-host"),
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
    let stopSuspension: TestSuspension?

    init(stopSuspension: TestSuspension? = nil) {
      self.stopSuspension = stopSuspension
    }

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

    func publishReady(_ devices: [Device]) {
      ready.continuation.yield(devices)
    }

    func stopTracking() async {
      try? await stopSuspension?.wait()
      stopped = true
      connected.continuation.finish()
      ready.continuation.finish()
      state.continuation.finish()
    }
  }
}
