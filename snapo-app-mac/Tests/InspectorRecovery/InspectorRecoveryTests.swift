import Foundation
import Network
import SnapODeviceClient

actor ADBService {
  let client = ADBClient()
  func exec() -> ADBClient {
    client
  }
}

private final class InspectorHTTP: @unchecked Sendable {
  static let state = State()

  final class State: @unchecked Sendable {
    private let lock = NSLock()
    private var frozenRequests = 0
    private var frozen = true
    private var networkDisconnected = false
    var count: Int {
      lock.withLock { frozenRequests }
    }

    func unfreeze() {
      lock.withLock { frozen = false }
    }

    func disconnectNetwork() {
      lock.withLock { networkDisconnected = true }
    }

    func shouldFail(port: Int?) -> Bool {
      lock.withLock {
        guard port == 12345 || port == 12344 else { return false }
        frozenRequests += 1
        return frozen || (port == 12344 && networkDisconnected)
      }
    }
  }

  private var listeners: [NWListener] = []
  private let lock = NSLock()
  private var sockets: [NWConnection] = []

  func start() async throws {
    for port: UInt16 in [12344, 12345, 12346] {
      let parameters = NWParameters.tcp
      parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
      let listener = try NWListener(using: parameters)
      listener.newConnectionHandler = { connection in
        self.lock.withLock { self.sockets.append(connection) }
        connection.start(queue: .global())
        self.read(connection, port: port)
      }
      listeners.append(listener)
      try await withCheckedThrowingContinuation { (ready: CheckedContinuation<Void, Error>) in
        listener.stateUpdateHandler = { state in
          switch state {
          case .ready: ready.resume()
          case .failed(let error): ready.resume(throwing: error)
          default: break
          }
        }
        listener.start(queue: .global())
      }
    }
  }

  func stop() {
    listeners.forEach { $0.cancel() }
    lock.withLock { sockets.forEach { $0.cancel() } }
  }

  private func read(_ connection: NWConnection, port: UInt16, previous: Data = Data()) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { data, _, _, _ in
      guard let data, !data.isEmpty else { return }
      let request = previous + data
      guard request.range(of: Data("\r\n\r\n".utf8)) != nil else {
        self.read(connection, port: port, previous: request)
        return
      }
      if Self.state.shouldFail(port: Int(port)) { return }
      precondition(String(decoding: request, as: UTF8.self).hasPrefix("OPTIONS / HTTP/1.1"))
      let status = "204 No Content"
      let body = ""
      let response = "HTTP/1.1 \(status)\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
      connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
    }
  }
}

enum SnapOLog {
  static let tracker = 0
}

@main
@MainActor
struct InspectorRecoveryTests {
  static func main() async throws {
    let http = InspectorHTTP()
    try await http.start()
    defer { http.stop() }
    let adbService = ADBService()
    let adb = await adbService.exec()
    let tracker = DeviceTracker(adbService: adbService)
    await tracker.startTracking()
    let payload = "frozen device transport_id:1\nhealthy device transport_id:2\nstalled device transport_id:3"
    adb.emitDevices(payload)
    try await eventually { await tracker.latestDevices.map(\.id) == ["frozen", "healthy"] }
    let service = InspectorService(adbService: adbService, deviceTracker: tracker)
    let suite = "SnapOHostRecoveryTests.\(UUID().uuidString)"
    let preferences = UserDefaults(suiteName: suite)!
    preferences.set(#"{"apps":[]}"#, forKey: "inspectorPreferences")
    defer { preferences.removePersistentDomain(forName: suite) }
    let host = AppInspectorModel(
      preferences: preferences,
      discover: { await service.discoverInspectors() },
      changes: { await service.changes() },
      currentDiscovery: { await service.currentInspectors() },
      openApp: { try await service.openApp($0) },
      sleep: { _ in try await Task.sleep(for: .seconds(3600)) }
    )
    host.start()
    try await eventually {
      let apps = host.snapshot.state.apps
      return apps.count == 2 && apps.first(where: { $0.deviceId == "healthy" })?.inspectors.allSatisfy(\.isConnected) == true
    }
    precondition(host.snapshot.state.apps.allSatisfy { $0.name == "com.example.demo" && $0.appIconBase64 == nil })
    print("Initial app labels use process names while manifest reads are still pending")
    let initialOrder = host.snapshot.state.apps.map(\.id)
    host.selectApp(host.snapshot.state.apps.first { $0.deviceId == "healthy" }!)
    precondition(host.snapshot.state.selection?.server.deviceId == "healthy")
    precondition(adb.scannedDeviceIDs.count == 2, "HTTP readiness reaches the UI without another device scan")
    print("Native discovery publishes and selects healthy apps beside stalled devices")
    let frozen = InspectorServerReference(deviceId: "frozen", socketName: "snapo_tweaks_42")
    let healthy = InspectorServerReference(deviceId: "healthy", socketName: "snapo_tweaks_42")
    _ = await service.discoverInspectors().apps
    try await eventually {
      let apps = await service.discoverInspectors().apps
      return InspectorHTTP.state.count == 2 && apps.count == 2
        && apps.first(where: { $0.deviceId == "frozen" })?.inspectors.allSatisfy { !$0.isConnected } == true
    }
    let count = adb.forwardCount
    for _ in 0 ..< 50 {
      _ = await service.discoverInspectors().apps
      do {
        _ = try await service.inspectorEndpoint(for: frozen)
        fatalError("Frozen inspector should remain disconnected during cooldown")
      } catch InspectorError.serverNotConnected {}
    }
    precondition(adb.forwardCount == count)
    precondition(InspectorHTTP.state.count == 2)
    precondition(!adb.scannedDeviceIDs.contains("stalled"))
    print("A device with failed properties is excluded from app discovery")
    do {
      _ = try await service.inspectorEndpoint(for: healthy)
      fatalError("Metadata must be verified before authorizing an endpoint")
    } catch InspectorError.serverNotConnected {}
    print("Both inspector kinds suppress repeated failed connections while healthy inspectors remain usable")

    adb.setMetadataAvailable(true)
    let scansBeforeMetadata = adb.scannedDeviceIDs.count
    try await eventually {
      let app = host.snapshot.state.apps.first { $0.deviceId == "frozen" }
      return app?.name == "Demo" && app?.appIconBase64 == "icon-frozen"
    }
    precondition(adb.scannedDeviceIDs.count == scansBeforeMetadata, "Completed metadata reaches the UI without another device scan")
    host.stop()
    let frozenMetadata = await service.discoverInspectors().apps.first { $0.deviceId == "frozen" }!
    precondition(frozenMetadata.inspectors.allSatisfy { !$0.isConnected })
    print("App metadata loads while inspector HTTP servers remain frozen")
    InspectorHTTP.state.unfreeze()
    try await Task.sleep(for: .milliseconds(3200))
    try await eventually {
      let app = await service.discoverInspectors().apps.first { $0.deviceId == "frozen" }
      return app?.inspectors.allSatisfy(\.isConnected) == true && app?.appIconBase64 != nil
    }
    let discovered = await service.discoverInspectors().apps.first { $0.deviceId == "frozen" }!
    precondition(discovered.name == "Demo" && discovered.inspectors.allSatisfy { $0.protocolVersion == ($0.kind == .network ? 3 : 7) })
    _ = try await service.inspectorEndpoint(for: frozen)
    precondition(adb.forwardCount == count + 2)
    print("Both inspector kinds reconnect automatically after cooldown")

    InspectorHTTP.state.disconnectNetwork()
    try await eventually {
      let apps = await service.discoverInspectors().apps
      let options = apps.first(where: { $0.deviceId == "frozen" })?.inspectors
      return options?.first(where: { $0.kind == .network })?.isConnected == false
        && options?.first(where: { $0.kind == .tweaks })?.isConnected == true
    }
    let disconnectedCount = adb.forwardCount
    for _ in 0 ..< 50 {
      let apps = await service.discoverInspectors().apps
      precondition(apps.map(\.id) == initialOrder)
      let cached = apps.first { $0.deviceId == "frozen" }!
      precondition(cached.name == discovered.name && cached.appIconBase64 == discovered.appIconBase64)
      precondition(cached.packageName == discovered.packageName && cached.androidUserId == discovered.androidUserId)
      precondition(cached.inspectors.map(\.kind) == [.network, .tweaks])
      precondition(cached.inspectors.allSatisfy { $0.protocolVersion == ($0.kind == .network ? 3 : 7) })
    }
    precondition(adb.forwardCount == disconnectedCount)
    _ = try await service.inspectorEndpoint(for: frozen)
    print("A connection failure retains app metadata, inspector options, and row order")

    adb.setMetadataAvailable(false)
    adb.replaceListeners()
    let replaced = await service.discoverInspectors().apps.first { $0.deviceId == "frozen" }!
    precondition(replaced.name == discovered.name && replaced.appIconBase64 == discovered.appIconBase64)
    precondition(replaced.inspectors.allSatisfy { !$0.isConnected })
    do {
      _ = try await service.inspectorEndpoint(for: frozen)
      fatalError("A replacement listener needs fresh process metadata before connecting")
    } catch InspectorError.serverNotConnected {}
    adb.setMetadataAvailable(true)
    try await eventually {
      await service.discoverInspectors().apps.first { $0.deviceId == "frozen" }?
        .inspectors.first { $0.kind == .tweaks }?.isConnected == true
    }
    print("A replacement listener keeps cached metadata while its process identity is verified")

    adb.setSocketNames([], deviceID: "frozen")
    let remainingApps = await service.discoverInspectors().apps
    precondition(remainingApps.map(\.deviceId) == ["healthy"])
    adb.setSocketNames(["snapo_network_42"], deviceID: "frozen")
    let returnedApps = await service.discoverInspectors().apps
    precondition(returnedApps.map(\.id) == initialOrder)
    let returned = returnedApps.first { $0.deviceId == "frozen" }!
    precondition(returned.name == discovered.name && returned.appIconBase64 == discovered.appIconBase64)
    precondition(returned.inspectors.count == 1 && returned.inspectors[0].protocolVersion == 3)
    precondition(!returned.inspectors[0].isConnected, "Cached metadata does not authorize an unverified connection")

    adb.setMetadataAvailable(false)
    adb.setSocketNames(["snapo_network_43"], deviceID: "frozen")
    let replacement = await service.discoverInspectors().apps.first { $0.deviceId == "frozen" }!
    precondition(replacement.id != discovered.id && replacement.name == "com.example.demo:worker")
    precondition(replacement.appIconBase64 == nil && replacement.inspectors[0].protocolVersion == nil)
    print("Socket rediscovery reuses metadata, but a different socket starts without cached information")
    await service.stop()
    let stoppedApps = await service.discoverInspectors().apps
    precondition(stoppedApps.isEmpty)
    adb.setSocketNames(["snapo_network_42", "snapo_tweaks_42"], deviceID: "frozen")

    let restarted = InspectorService(adbService: adbService, deviceTracker: tracker)
    try await eventually {
      await restarted.discoverInspectors().apps.first { $0.deviceId == "frozen" }?
        .inspectors.first { $0.kind == .tweaks }?.isConnected == true
    }
    let restartedApp = await restarted.discoverInspectors().apps.first { $0.deviceId == "frozen" }!
    precondition(
      restartedApp.inspectors.first { $0.kind == .network }?.protocolVersion == nil,
      "Metadata is not shared across service instances"
    )
    adb.setMetadataAvailable(true)
    try await eventually {
      await restarted.discoverInspectors().apps.first { $0.deviceId == "frozen" }?
        .inspectors.first { $0.kind == .tweaks }?.compatibility == .supported
    }
    let ownerID = UUID()
    var invalidated = false
    var retired = false
    var releasePage: CheckedContinuation<Void, Never>?
    let beforeRetirement = adb.removedPorts.count(where: { $0 == 12345 })
    _ = try await restarted.inspectorEndpoint(for: frozen, ownerID: ownerID, invalidated: {
      invalidated = true
      await withCheckedContinuation { releasePage = $0 }
      retired = true
    })
    let stop = Task { await restarted.stop() }
    try await eventually { invalidated }
    precondition(
      adb.removedPorts.count(where: { $0 == 12345 }) == beforeRetirement,
      "The forward stays reserved while an authorized page is still unloading"
    )
    releasePage?.resume()
    await stop.value
    precondition(retired && adb.removedPorts.count(where: { $0 == 12345 }) == beforeRetirement + 1)
    print("Endpoint retirement waits for the page before releasing its forwarded port")
    print("A new service instance can reconnect immediately")

    adb.setMetadataAvailable(true)
    adb.recoverProperties()
    try await eventually { await tracker.latestDevices.map(\.id) == ["frozen", "healthy", "stalled"] }
    let recovered = InspectorService(adbService: adbService, deviceTracker: tracker)
    _ = await recovered.discoverInspectors().apps
    precondition(adb.scannedDeviceIDs.contains("stalled"))
    await recovered.stop()
    let failingPayload = "forward-failure device transport_id:4"
    adb.emitDevices(failingPayload)
    try await eventually { await tracker.latestDevices.map(\.id) == ["forward-failure"] }
    let forwardFailure = InspectorService(adbService: adbService, deviceTracker: tracker)
    let beforeForwardFailure = adb.forwardCount
    for _ in 0 ..< 50 {
      _ = await forwardFailure.discoverInspectors().apps
    }
    precondition(adb.forwardCount == beforeForwardFailure + 2)
    let failedApps = await forwardFailure.discoverInspectors().apps
    precondition(failedApps.count == 1 && failedApps[0].inspectors.count == 2)
    precondition(failedApps[0].inspectors.allSatisfy { !$0.isConnected })
    try await eventually {
      await forwardFailure.discoverInspectors().apps.first?.appIconBase64 == "icon-forward-failure"
    }
    await forwardFailure.stop()
    print("Port forwarding failures enter the same cooldown as failed inspector requests")
    await tracker.stopTracking()
    print("Property failures recover without another device tracking event")
    try await refreshesSiblingDescriptors()
    try compatibilityStates()
    try await normalizesMetadata()
    try await mixedCompatibility()
    try await preservesMetadataAfterFailure()
    try await restartsCanceledLegacyProbe()
  }

  static func refreshesSiblingDescriptors() async throws {
    let adbService = ADBService()
    let adb = await adbService.exec()
    adb.setMetadataAvailable(true)
    adb.setSocketNames(["snapo_network_42", "snapo_network_43"], deviceID: "healthy")
    let tracker = DeviceTracker(adbService: adbService)
    await tracker.startTracking()
    adb.emitDevices("healthy device transport_id:1")
    try await eventually { await tracker.latestDevices.count == 1 }
    let service = InspectorService(adbService: adbService, deviceTracker: tracker)
    _ = await service.discoverInspectors()
    try await eventually {
      await service.currentInspectors().apps.first?.metadata?.inspectors.map(\.id) == [.network]
    }
    precondition(adb.metadataSocketRequests.count == 1)
    precondition(Set(adb.metadataSocketRequests[0]) == ["snapo_network_42", "snapo_network_43"])

    let now = ContinuousClock.now
    var cachedApp = InspectorHTTPService.App(
      kind: .network, pid: 42, deviceID: "healthy", deviceDisplayTitle: "Phone", socketName: "snapo_network_42"
    )
    precondition(cachedApp.needsMetadataRead(lastAttempt: nil, now: now))
    precondition(!cachedApp.needsMetadataRead(lastAttempt: now, now: now.advanced(by: .seconds(29))))
    precondition(cachedApp.needsMetadataRead(lastAttempt: now, now: now.advanced(by: .seconds(30))))
    cachedApp.metadata.applyPackageMetadata(testManifest(pid: 42, kinds: [.network]), kind: .network)
    precondition(
      !cachedApp.needsMetadataRead(lastAttempt: now, now: now.advanced(by: .seconds(60))),
      "Successful metadata stays cached after the failed-read retry window"
    )
    cachedApp.awaitingMetadata = true
    precondition(cachedApp.needsMetadataRead(lastAttempt: nil, now: now), "A replacement socket invalidates cached metadata")
    precondition(!cachedApp.needsMetadataRead(lastAttempt: now, now: now), "Failed replacement reads still back off")

    adb.setSocketNames(["snapo_network_42", "snapo_network_43", "snapo_tweaks_42"], deviceID: "healthy")
    _ = await service.discoverInspectors()
    try await eventually {
      let app = await service.currentInspectors().apps.first
      return app?.metadata?.inspectors.map(\.id) == [.network, .tweaks]
        && app?.inspectors.map(\.protocolVersion) == [3, 7]
    }
    precondition(adb.metadataSocketRequests.count == 2)
    precondition(Set(adb.metadataSocketRequests[1]) == ["snapo_network_42", "snapo_tweaks_42"])
    _ = await service.discoverInspectors()
    precondition(adb.metadataSocketRequests.count == 2, "An unchanged socket set keeps cached metadata")

    adb.setSocketNames(["snapo_network_42"], deviceID: "healthy")
    let remaining = await service.discoverInspectors().apps.first!
    precondition(remaining.metadata?.inspectors.map(\.id) == [.network, .tweaks])
    precondition(remaining.inspectors.map(\.kind) == [.network], "A cached descriptor cannot make an absent server available")
    await service.stop()
    await tracker.stopTracking()
    print("A new socket refreshes sibling metadata; only live sockets determine inspector availability")
  }

  static func compatibilityStates() throws {
    func status(inspectors: [[String: Any]], errors: [[String: String]] = []) throws -> InspectorCompatibility {
      let record: [String: Any] = [
        "version": 1, "pid": 42, "processIdentity": "boot:42:1", "androidUserId": 0,
        "app": ["name": "Demo", "packageName": "com.example.demo", "revision": "1", "inspectors": inspectors, "errors": errors]
      ]
      let manifest = try JSONDecoder().decode(InspectorProcessMetadata.self, from: JSONSerialization.data(withJSONObject: record))
      var metadata = InspectorMetadata()
      metadata.applyPackageMetadata(manifest, kind: .network)
      return InspectorHTTPService.App(
        kind: .network, pid: 42, deviceID: "phone", deviceDisplayTitle: "Phone", socketName: "snapo_network_42", metadata: metadata
      ).compatibility
    }
    let descriptor: [String: Any] = ["id": "network", "name": "Network", "protocolVersion": 3]
    let missingFrontend = try status(inspectors: [descriptor])
    precondition(missingFrontend == .missingFrontend(protocolVersion: 3))
    let missingDescriptor = try status(inspectors: [])
    precondition(missingDescriptor == .missingDescriptor)
    let invalidDescriptor = try status(inspectors: [], errors: [["key": "snapo.inspector.network", "error": "Invalid XML"]])
    precondition(invalidDescriptor == .invalidDescriptor)
    let siblingError = try status(inspectors: [], errors: [["key": "snapo.inspector.tweaks", "error": "Invalid XML"]])
    precondition(siblingError == .missingDescriptor)
    for version in [0, 1, 2] {
      var value = descriptor
      value["frontend"] = ["assetPath": "frontend.zip", "hostApiVersion": version]
      let actual = try status(inspectors: [value])
      precondition(actual == (version == 1 ? .supported : .hostAPI(version: version)))
    }
    var pending = InspectorHTTPService.App(
      kind: .network,
      pid: 42,
      deviceID: "phone",
      deviceDisplayTitle: "Phone",
      socketName: "snapo_network_42"
    )
    precondition(pending.compatibility == .unknown)
    pending.metadataReadFailed = true
    precondition(pending.compatibility == .metadataUnavailable && !pending.compatibility.isUnsupported)
    print("Missing metadata, invalid descriptors, missing frontends, and host API versions remain distinct")
  }

  static func normalizesMetadata() async throws {
    let adb = ADBClient()
    adb.setLegacyKinds([.network])
    let legacy = try await adb.legacyInspectorMetadata(
      reference: InspectorServerReference(deviceId: "phone", socketName: "snapo_network_42"), kind: .network, pid: 42
    )!
    func record(
      package: String = "com.example.demo",
      processName: String = "com.example.demo",
      revision: String = "1",
      kinds: [InspectorID] = []
    ) throws -> InspectorProcessMetadata {
      let value: [String: Any] = [
        "version": 1, "pid": 42, "processIdentity": "boot:42:1", "androidUserId": 0, "processName": processName,
        "app": [
          "name": "Package label",
          "packageName": package,
          "revision": revision,
          "inspectors": kinds.map { kind in
            [
              "id": kind.rawValue,
              "name": kind.rawValue,
              "protocolVersion": 4,
              "frontend": ["assetPath": "frontend.zip", "hostApiVersion": 1]
            ] as [String: Any]
          }
        ]
      ]
      return try JSONDecoder().decode(InspectorProcessMetadata.self, from: JSONSerialization.data(withJSONObject: value))
    }
    var metadata = InspectorMetadata()
    precondition(metadata.applyLegacyMetadata(legacy, kind: .network))
    precondition(metadata.process.name == "Demo" && metadata.process.packageName == "com.example.demo")
    precondition(metadata.process.verifiedIdentity == nil && metadata.process.inspectors.isEmpty)
    precondition(metadata.compatibility == .legacy(protocolVersion: 1))
    let legacyConnection = try JSONSerialization.jsonObject(with: JSONEncoder().encode(
      InspectorConnectionState(metadata: metadata.process)
    )) as! [String: Any]
    precondition(legacyConnection["manifest"] == nil)

    let modern = try record(kinds: [.network])
    precondition(metadata.applyPackageMetadata(modern, kind: .network))
    precondition(metadata.process.name == "Package label" && metadata.process.verifiedIdentity != nil)
    precondition(metadata.compatibility == .supported && metadata.protocolVersion == 4)
    precondition(!metadata.applyLegacyMetadata(legacy, kind: .network))

    let withoutDescriptor = try record()
    metadata.applyPackageMetadata(withoutDescriptor, kind: .network)
    precondition(metadata.applyLegacyMetadata(legacy, kind: .network))
    precondition(metadata.process.name == "Package label")
    let sibling = try record(kinds: [.tweaks])
    metadata.applyPackageMetadata(sibling, kind: .network)
    precondition(metadata.compatibility == .legacy(protocolVersion: 1))
    let replacement = try record(revision: "2")
    metadata.applyPackageMetadata(replacement, kind: .network)
    precondition(metadata.compatibility == .missingDescriptor && metadata.protocolVersion == nil)

    for mismatch in try [record(package: "com.example.other"), record(processName: "com.example.demo:other")] {
      metadata.applyPackageMetadata(mismatch, kind: .network)
      let previous = metadata
      precondition(!metadata.applyLegacyMetadata(legacy, kind: .network) && metadata == previous)
    }
    print("Metadata normalization merges display fields, preserves verified identity, and rejects stale or conflicting legacy evidence")
  }

  static func mixedCompatibility() async throws {
    let adbService = ADBService()
    let adb = await adbService.exec()
    adb.setMetadataAvailable(true)
    adb.setLegacyKinds([.network])
    let tracker = DeviceTracker(adbService: adbService)
    await tracker.startTracking()
    adb.emitDevices("healthy device transport_id:1")
    try await eventually { await tracker.latestDevices.count == 1 }
    let service = InspectorService(adbService: adbService, deviceTracker: tracker)
    try await eventually {
      let options = await service.discoverInspectors().apps.first?.inspectors
      return options?.first { $0.kind == .network }?.compatibility == .legacy(protocolVersion: 1)
        && options?.first { $0.kind == .tweaks }?.compatibility == .supported
        && options?.allSatisfy(\.isConnected) == true
    }
    let app = await service.currentInspectors().apps.first!
    precondition(app.inspectors.count == 2)
    var selection = InspectorSelection()
    selection.reconcile([app])
    precondition(selection.state.preferredKind == .tweaks, "Initial selection prefers a compatible sibling")
    selection.selectInspector(app, option: app.inspectors[0])
    precondition(selection.state.preferredKind == .network, "Unsupported inspectors remain selectable")
    do {
      _ = try await service.inspectorEndpoint(for: app.inspectors[0].server)
      fatalError("Legacy metadata must not authorize an inspector endpoint")
    } catch InspectorError.serverNotConnected {}
    _ = try await service.inspectorEndpoint(for: app.inspectors[1].server)
    for _ in 0 ..< 5 {
      _ = await service.discoverInspectors()
    }
    precondition(adb.legacyRequestCount == 1, "Known legacy metadata is cached and modern siblings are not probed")
    adb.setLegacyKinds([])
    adb.replaceListeners()
    try await eventually {
      await service.discoverInspectors().apps.first?.inspectors.allSatisfy { $0.compatibility == .supported } == true
    }
    precondition(adb.legacyRequestCount == 1, "Replacement listeners use fresh manifests before legacy detection")
    await service.stop()
    await tracker.stopTracking()
    print("Unsupported inspectors remain visible and selectable beside usable siblings; listener replacement clears compatibility")
  }

  private static func refresh(_ service: InspectorHTTPService, using adb: ADBClient) async {
    let device = Device(id: "healthy", model: "Phone", androidVersion: "Test", vendorModel: nil, manufacturer: nil, avdName: nil)
    let sockets = await InspectorDiscovery.discover(on: [device.id], using: adb)
    await service.refresh(devices: [device], sockets: sockets, using: adb)
  }

  static func preservesMetadataAfterFailure() async throws {
    for failure: ADBClient.MetadataFailure in [.request, .record] {
      let adbService = ADBService()
      let adb = await adbService.exec()
      adb.setMetadataAvailable(true)
      adb.setSocketNames(["snapo_network_42"], deviceID: "healthy")
      let service = InspectorHTTPService(adbService: adbService)
      await refresh(service, using: adb)
      try await eventually {
        let app = await service.currentApps().apps.first
        return app?.compatibility == .supported && app?.isConnected == true
      }
      let original = await service.currentApps().apps.first!
      let network = InspectorServerReference(deviceId: "healthy", socketName: "snapo_network_42")
      let tweaks = InspectorServerReference(deviceId: "healthy", socketName: "snapo_tweaks_42")
      adb.setMetadataFailure(failure)
      adb.setSocketNames([network.socketName, tweaks.socketName], deviceID: "healthy")
      await refresh(service, using: adb)
      try await eventually {
        let apps = await service.currentApps().apps
        return apps.count == 2 && apps.allSatisfy(\.metadataReadFailed) && !apps.contains(where: \.checkingLegacy)
      }
      let failed = await service.currentApps().apps
      precondition(failed[0].metadata.process == original.metadata.process, "Failed sibling discovery must preserve verified metadata")
      precondition(failed[0].compatibility == .supported && failed[0].isConnected)
      precondition(failed[1].compatibility == .metadataUnavailable)
      _ = try await service.endpoint(for: network)
      do {
        _ = try await service.endpoint(for: tweaks)
        fatalError("A new sibling cannot use another socket's cached descriptor")
      } catch InspectorError.serverNotConnected {}
      let now = ContinuousClock.now
      precondition(!failed[0].needsMetadataRead(lastAttempt: now, now: now.advanced(by: .seconds(29))))
      precondition(failed[0].needsMetadataRead(lastAttempt: now, now: now.advanced(by: .seconds(30))))
      await refresh(service, using: adb)
      precondition(adb.metadataSocketRequests.count == 2, "Failed metadata refreshes must still back off")

      adb.replaceListeners()
      await refresh(service, using: adb)
      try await eventually {
        let apps = await service.currentApps().apps
        return adb.metadataSocketRequests.count == 3 && apps.allSatisfy(\.metadataReadFailed)
      }
      let replacement = await service.currentApps().apps.first!
      precondition(replacement.metadata.process == original.metadata.process, "Retain display metadata while a replacement is unverified")
      precondition(replacement.awaitingMetadata && !replacement.isConnected && replacement.compatibility == .metadataUnavailable)
      do {
        _ = try await service.endpoint(for: network)
        fatalError("Preserved metadata cannot authorize a replacement listener after a failed read")
      } catch InspectorError.serverNotConnected {}

      adb.setMetadataFailure(nil)
      adb.replaceListeners()
      await refresh(service, using: adb)
      try await eventually {
        await service.currentApps().apps.allSatisfy { $0.compatibility == .supported && $0.isConnected && !$0.metadataReadFailed }
      }
      _ = try await service.endpoint(for: network)
      _ = try await service.endpoint(for: tweaks)
      await service.stop()
    }
    print("Failed refreshes preserve verified siblings, back off, and never authorize unverified replacement listeners")
  }

  static func restartsCanceledLegacyProbe() async throws {
    let adbService = ADBService()
    let adb = await adbService.exec()
    adb.setMetadataAvailable(true)
    adb.setLegacyKinds([.network])
    adb.setLegacyBlocked(true)
    adb.setSocketNames(["snapo_network_42"], deviceID: "healthy")
    let service = InspectorHTTPService(adbService: adbService)
    await refresh(service, using: adb)
    try await eventually {
      await service.currentApps().apps.first?.checkingLegacy == true && adb.legacyRequestCount == 1
    }
    adb.setSocketNames([], deviceID: "healthy")
    await refresh(service, using: adb)
    try await eventually { adb.legacyCancellationCount == 1 }
    adb.setSocketNames(["snapo_network_42"], deviceID: "healthy")
    await refresh(service, using: adb)
    try await eventually { adb.legacyRequestCount == 2 }
    let returned = await service.currentApps().apps.first!
    precondition(!returned.checkingLegacy, "A canceled probe must not leave the cached loading flag set")
    precondition(adb.metadataSocketRequests.count == 2, "Rediscovery must not wait for the failed-request cooldown")
    adb.setLegacyBlocked(false)
    try await eventually { await service.currentApps().apps.first?.compatibility == .legacy(protocolVersion: 1) }
    adb.setLegacyBlocked(true)
    adb.replaceListeners()
    await refresh(service, using: adb)
    try await eventually { adb.legacyRequestCount == 3 }
    await service.stop()
    try await eventually { adb.legacyCancellationCount == 2 }
    print("Socket removal clears canceled probe state; rediscovery retries immediately and shutdown cancels active probes")
  }

  static func eventually(line: Int = #line, _ condition: () async -> Bool) async throws {
    for _ in 0 ..< 500 {
      if await condition() { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    fatalError("Condition at line \(line) did not become true")
  }
}
