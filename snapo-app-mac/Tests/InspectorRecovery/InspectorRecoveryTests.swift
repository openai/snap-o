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
    let service = try InspectorService(adbService: adbService, deviceTracker: tracker, registry: testPluginRegistry())
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
    _ = try await service.inspectorEndpoint(for: healthy)
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

    let restarted = try InspectorService(adbService: adbService, deviceTracker: tracker, registry: testPluginRegistry())
    try await eventually {
      await restarted.discoverInspectors().apps.first { $0.deviceId == "frozen" }?
        .inspectors.first { $0.kind == .tweaks }?.isConnected == true
    }
    let restartedApp = await restarted.discoverInspectors().apps.first { $0.deviceId == "frozen" }!
    precondition(
      restartedApp.inspectors.first { $0.kind == .network }?.protocolVersion == nil,
      "Metadata is not shared across service instances"
    )
    _ = try await restarted.inspectorEndpoint(for: frozen)
    await restarted.stop()
    print("A new service instance can reconnect immediately")

    adb.setMetadataAvailable(true)
    adb.recoverProperties()
    try await eventually { await tracker.latestDevices.map(\.id) == ["frozen", "healthy", "stalled"] }
    let recovered = try InspectorService(adbService: adbService, deviceTracker: tracker, registry: testPluginRegistry())
    _ = await recovered.discoverInspectors().apps
    precondition(adb.scannedDeviceIDs.contains("stalled"))
    await recovered.stop()
    let failingPayload = "forward-failure device transport_id:4"
    adb.emitDevices(failingPayload)
    try await eventually { await tracker.latestDevices.map(\.id) == ["forward-failure"] }
    let forwardFailure = try InspectorService(adbService: adbService, deviceTracker: tracker, registry: testPluginRegistry())
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
    let service = try InspectorService(adbService: adbService, deviceTracker: tracker, registry: testPluginRegistry())
    _ = await service.discoverInspectors()
    try await eventually {
      await service.currentInspectors().apps.first?.manifest?.app?.inspectors.map(\.id) == [.network]
    }
    precondition(adb.metadataSocketRequests.count == 1)
    precondition(Set(adb.metadataSocketRequests[0]) == ["snapo_network_42", "snapo_network_43"])

    let now = ContinuousClock.now
    var cachedApp = InspectorHTTPService.App(
      kind: .network, pid: 42, deviceID: "healthy", deviceDisplayTitle: "Phone", socketName: "snapo_network_42"
    )
    precondition(cachedApp.needsManifestRead(lastAttempt: nil, now: now))
    precondition(!cachedApp.needsManifestRead(lastAttempt: now, now: now.advanced(by: .seconds(29))))
    precondition(cachedApp.needsManifestRead(lastAttempt: now, now: now.advanced(by: .seconds(30))))
    cachedApp.manifest = await service.currentInspectors().apps.first!.manifest!
    precondition(
      !cachedApp.needsManifestRead(lastAttempt: now, now: now.advanced(by: .seconds(60))),
      "Successful metadata stays cached after the failed-read retry window"
    )
    cachedApp.awaitingManifest = true
    precondition(cachedApp.needsManifestRead(lastAttempt: nil, now: now), "A replacement socket invalidates cached metadata")
    precondition(!cachedApp.needsManifestRead(lastAttempt: now, now: now), "Failed replacement reads still back off")

    adb.setSocketNames(["snapo_network_42", "snapo_network_43", "snapo_tweaks_42"], deviceID: "healthy")
    _ = await service.discoverInspectors()
    try await eventually {
      let app = await service.currentInspectors().apps.first
      return app?.manifest?.app?.inspectors.map(\.id) == [.network, .tweaks]
        && app?.inspectors.map(\.protocolVersion) == [3, 7]
    }
    precondition(adb.metadataSocketRequests.count == 2)
    precondition(Set(adb.metadataSocketRequests[1]) == ["snapo_network_42", "snapo_tweaks_42"])
    _ = await service.discoverInspectors()
    precondition(adb.metadataSocketRequests.count == 2, "An unchanged socket set keeps cached metadata")

    adb.setSocketNames(["snapo_network_42"], deviceID: "healthy")
    let remaining = await service.discoverInspectors().apps.first!
    precondition(remaining.manifest?.app?.inspectors.map(\.id) == [.network, .tweaks])
    precondition(remaining.inspectors.map(\.kind) == [.network], "A cached descriptor cannot make an absent server available")
    await service.stop()
    await tracker.stopTracking()
    print("A new socket refreshes sibling metadata; only live sockets determine inspector availability")
  }

  static func eventually(line: Int = #line, _ condition: () async -> Bool) async throws {
    for _ in 0 ..< 500 {
      if await condition() { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    fatalError("Condition at line \(line) did not become true")
  }
}
