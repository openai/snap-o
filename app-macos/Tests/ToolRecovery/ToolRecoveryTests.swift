import Foundation

actor ADBService {
  let client = ADBClient()
  func exec() -> ADBClient {
    client
  }
}

enum SnapOLog {
  static let tracker = 0
}

@main
@MainActor
struct ToolRecoveryTests {
  static func main() async throws {
    let adbService = ADBService()
    let adb = await adbService.exec()
    adb.setToolOrder(["tweaks"])
    let tracker = DeviceTracker(adbService: adbService)
    await tracker.startTracking()
    let payload = "frozen device transport_id:1\nhealthy device transport_id:2\nstalled device transport_id:3"
    adb.emitDevices(payload)
    try await eventually { await tracker.latestDevices.map(\.id) == ["frozen", "healthy"] }
    let service = ToolService(adbService: adbService, deviceTracker: tracker)
    let suite = "SnapOHostRecoveryTests.\(UUID().uuidString)"
    let preferences = UserDefaults(suiteName: suite)!
    preferences.set(#"{"apps":[]}"#, forKey: "inspectorPreferences")
    defer { preferences.removePersistentDomain(forName: suite) }
    let host = AppToolModel(
      preferences: preferences,
      discover: { await service.discoverPlugins() },
      changes: { await service.changes() },
      currentDiscovery: { await service.currentPlugins() },
      openApp: { try await service.openApp($0) },
      sleep: { _ in try await Task.sleep(for: .seconds(3600)) }
    )
    host.start()
    try await eventually {
      let apps = host.snapshot.state.apps
      return apps.count == 2 && apps.first(where: { $0.deviceId == "healthy" })?.tools.allSatisfy(\.isConnected) == true
    }
    precondition(host.snapshot.state.apps.allSatisfy { $0.name == "com.example.demo" && $0.appIconBase64 == nil })
    print("Initial app labels use process names while manifest reads are still pending")
    let initialOrder = host.snapshot.state.apps.map(\.id)
    precondition(host.snapshot.state.selection == nil, "Automatic selection waits for the app tool order")
    precondition(adb.scannedDeviceIDs.count == 2, "HTTP readiness reaches the UI without another device scan")
    print("Native discovery publishes healthy apps without selecting a tool before metadata loads")
    let frozen = ToolServerReference(deviceId: "frozen", socketName: "snapo_tweaks_42")
    let healthy = ToolServerReference(deviceId: "healthy", socketName: "snapo_tweaks_42")
    _ = await service.discoverPlugins().apps
    try await eventually {
      let apps = await service.discoverPlugins().apps
      return adb.failedToolConnectionCount == 2 && apps.count == 2
        && apps.first(where: { $0.deviceId == "frozen" })?.tools.allSatisfy { !$0.isConnected } == true
    }
    for _ in 0 ..< 5 {
      _ = await service.discoverPlugins().apps
      do {
        _ = try await service.pluginEndpoint(for: frozen)
        fatalError("Frozen tool should remain disconnected during cooldown")
      } catch ToolError.serverNotConnected {}
    }
    precondition(adb.failedToolConnectionCount == 2)
    precondition(!adb.scannedDeviceIDs.contains("stalled"))
    print("A device with failed properties is excluded from app discovery")
    do {
      _ = try await service.pluginEndpoint(for: healthy)
      fatalError("Metadata must be verified before authorizing an endpoint")
    } catch ToolError.serverNotConnected {}
    print("Both tool kinds suppress repeated failed connections while healthy tools remain usable")

    adb.setMetadataAvailable(true)
    let scansBeforeMetadata = adb.scannedDeviceIDs.count
    try await eventually {
      let app = host.snapshot.state.apps.first { $0.deviceId == "frozen" }
      return app?.name == "Demo" && app?.appIconBase64 == "icon-frozen"
    }
    precondition(adb.scannedDeviceIDs.count == scansBeforeMetadata, "Completed metadata reaches the UI without another device scan")
    let frozenMetadata = await service.discoverPlugins().apps.first { $0.deviceId == "frozen" }!
    precondition(frozenMetadata.tools.allSatisfy { !$0.isConnected })
    precondition(frozenMetadata.tools.map(\.kind) == [.tweaks, .network])
    try await eventually { host.snapshot.state.selectedApp?.tools.map(\.kind) == [.tweaks, .network] }
    precondition(host.snapshot.state.selection?.server.deviceId == "healthy")
    precondition(host.snapshot.state.selection?.kind == .tweaks, "Initial selection follows the delayed app order")
    print("App metadata loads while tool HTTP servers remain frozen")
    adb.unfreeze()
    try await Task.sleep(for: .milliseconds(3200))
    try await eventually {
      let app = await service.discoverPlugins().apps.first { $0.deviceId == "frozen" }
      return app?.tools.allSatisfy(\.isConnected) == true && app?.appIconBase64 != nil
    }
    let discovered = await service.discoverPlugins().apps.first { $0.deviceId == "frozen" }!
    precondition(discovered.name == "Demo" && discovered.tools.allSatisfy { $0.compatibility == .supported })
    _ = try await service.pluginEndpoint(for: frozen)
    print("Both tool kinds reconnect automatically after cooldown")

    host.selectTool(discovered, option: discovered.tools.first { $0.kind == .network }!)
    precondition(host.snapshot.pageState(for: .network).isConnected)
    precondition(!host.snapshot.pageState(for: .tweaks).isConnected, "Hidden pages receive a disconnected state")
    adb.disconnectNetwork()
    try await eventually {
      let apps = await service.discoverPlugins().apps
      let options = apps.first(where: { $0.deviceId == "frozen" })?.tools
      return options?.first(where: { $0.kind == .network })?.isConnected == false
        && options?.first(where: { $0.kind == .tweaks })?.isConnected == true
    }
    try await eventually { !host.snapshot.pageState(for: .network).isConnected }
    host.stop()
    print("Connection updates notify the selected page when its server becomes unavailable")
    let disconnectedFailures = adb.failedToolConnectionCount
    for _ in 0 ..< 5 {
      let apps = await service.discoverPlugins().apps
      precondition(apps.map(\.id) == initialOrder)
      let cached = apps.first { $0.deviceId == "frozen" }!
      precondition(cached.name == discovered.name && cached.appIconBase64 == discovered.appIconBase64)
      precondition(cached.packageName == discovered.packageName && cached.androidUserId == discovered.androidUserId)
      precondition(cached.tools.map(\.kind) == [.tweaks, .network])
      precondition(cached.tools.allSatisfy { $0.compatibility == .supported })
    }
    precondition(adb.failedToolConnectionCount == disconnectedFailures)
    _ = try await service.pluginEndpoint(for: frozen)
    print("A connection failure retains app metadata, tool options, and row order")

    adb.setMetadataAvailable(false)
    adb.replaceListeners()
    let replaced = await service.discoverPlugins().apps.first { $0.deviceId == "frozen" }!
    precondition(replaced.name == discovered.name && replaced.appIconBase64 == discovered.appIconBase64)
    precondition(replaced.tools.allSatisfy { !$0.isConnected })
    do {
      _ = try await service.pluginEndpoint(for: frozen)
      fatalError("A replacement listener needs fresh process metadata before connecting")
    } catch ToolError.serverNotConnected {}
    adb.setMetadataAvailable(true)
    try await eventually {
      await service.discoverPlugins().apps.first { $0.deviceId == "frozen" }?
        .tools.first { $0.kind == .tweaks }?.isConnected == true
    }
    print("A replacement listener keeps cached metadata while its process identity is verified")

    adb.setSocketNames([], deviceID: "frozen")
    let remainingApps = await service.discoverPlugins().apps
    precondition(remainingApps.map(\.deviceId) == ["healthy"])
    adb.setSocketNames(["snapo_network_42"], deviceID: "frozen")
    let returnedApps = await service.discoverPlugins().apps
    precondition(returnedApps.map(\.id) == initialOrder)
    let returned = returnedApps.first { $0.deviceId == "frozen" }!
    precondition(returned.name == discovered.name && returned.appIconBase64 == discovered.appIconBase64)
    precondition(returned.tools.count == 1 && returned.tools[0].compatibility == .supported)
    precondition(!returned.tools[0].isConnected, "Cached metadata does not authorize an unverified connection")

    adb.setMetadataAvailable(false)
    adb.setSocketNames(["snapo_network_43"], deviceID: "frozen")
    let replacement = await service.discoverPlugins().apps.first { $0.deviceId == "frozen" }!
    precondition(replacement.id != discovered.id && replacement.name == "com.example.demo:worker")
    precondition(replacement.appIconBase64 == nil && replacement.tools[0].compatibility != .supported)
    print("Socket rediscovery reuses metadata, but a different socket starts without cached information")
    await service.stop()
    let stoppedApps = await service.discoverPlugins().apps
    precondition(stoppedApps.isEmpty)
    adb.setSocketNames(["snapo_network_42", "snapo_tweaks_42"], deviceID: "frozen")

    let restarted = ToolService(adbService: adbService, deviceTracker: tracker)
    try await eventually {
      await restarted.discoverPlugins().apps.first { $0.deviceId == "frozen" }?
        .tools.first { $0.kind == .tweaks }?.isConnected == true
    }
    let restartedApp = await restarted.discoverPlugins().apps.first { $0.deviceId == "frozen" }!
    precondition(
      restartedApp.metadata?.tools.isEmpty != false,
      "Metadata is not shared across service instances"
    )
    adb.setMetadataAvailable(true)
    try await eventually {
      await restarted.discoverPlugins().apps.first { $0.deviceId == "frozen" }?
        .tools.first { $0.kind == .tweaks }?.compatibility == .supported
    }
    _ = try await restarted.pluginEndpoint(for: frozen)
    await restarted.stop()
    do {
      _ = try await restarted.pluginEndpoint(for: frozen)
      fatalError("Stopped services must reject new endpoints")
    } catch ToolError.serverNotConnected {}
    print("A new service instance can reconnect immediately")

    adb.setMetadataAvailable(true)
    adb.recoverProperties()
    try await eventually { await tracker.latestDevices.map(\.id) == ["frozen", "healthy", "stalled"] }
    let recovered = ToolService(adbService: adbService, deviceTracker: tracker)
    _ = await recovered.discoverPlugins().apps
    precondition(adb.scannedDeviceIDs.contains("stalled"))
    await recovered.stop()
    let failingPayload = "direct-failure device transport_id:4"
    adb.emitDevices(failingPayload)
    try await eventually { await tracker.latestDevices.map(\.id) == ["direct-failure"] }
    let connectionFailure = ToolService(adbService: adbService, deviceTracker: tracker)
    let beforeConnectionFailure = adb.toolConnectionCount
    for _ in 0 ..< 5 {
      _ = await connectionFailure.discoverPlugins().apps
    }
    precondition(adb.toolConnectionCount == beforeConnectionFailure + 2)
    let failedApps = await connectionFailure.discoverPlugins().apps
    precondition(failedApps.count == 1 && failedApps[0].tools.count == 2)
    precondition(failedApps[0].tools.allSatisfy { !$0.isConnected })
    try await eventually {
      await connectionFailure.discoverPlugins().apps.first?.appIconBase64 == "icon-direct-failure"
    }
    await connectionFailure.stop()
    print("Direct connection failures enter the tool request cooldown")
    await tracker.stopTracking()
    print("Property failures recover without another device tracking event")
    try await refreshesSiblingDescriptors()
    try await filtersSocketFloods()
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
    let service = ToolService(adbService: adbService, deviceTracker: tracker)
    _ = await service.discoverPlugins()
    try await eventually {
      await service.currentPlugins().apps.first?.metadata?.tools.map(\.id) == [.network, .tweaks, .sample]
    }
    precondition(adb.metadataProcessRequests.count == 1)
    precondition(adb.metadataProcessRequests[0] == [42, 43])
    let initial = await service.currentPlugins().apps
    precondition(initial.allSatisfy { $0.tools.map(\.kind) == [.network] }, "A declaration alone cannot expose a tool")

    let now = ContinuousClock.now
    var cachedApp = ToolHTTPService.App(
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
    _ = await service.discoverPlugins()
    try await eventually {
      let app = await service.currentPlugins().apps.first
      return app?.tools.map(\.kind) == [.network, .tweaks]
        && app?.tools.allSatisfy { $0.compatibility == .supported } == true
    }
    precondition(adb.metadataProcessRequests.count == 2)
    precondition(adb.metadataProcessRequests[1] == [42])
    _ = await service.discoverPlugins()
    precondition(adb.metadataProcessRequests.count == 2, "An unchanged socket set keeps cached metadata")

    adb.setSocketNames(["snapo_network_42"], deviceID: "healthy")
    let remaining = await service.discoverPlugins().apps.first!
    precondition(remaining.metadata?.tools.map(\.id) == [.network, .tweaks, .sample])
    precondition(remaining.tools.map(\.kind) == [.network], "A cached descriptor cannot make an absent server available")
    await service.stop()
    await tracker.stopTracking()
    print("A new socket refreshes sibling metadata; only live sockets determine tool availability")
  }

  static func filtersSocketFloods() async throws {
    let adbService = ADBService()
    let adb = await adbService.exec()
    let noise = (0 ..< 1000).map { "snapo_noise\($0)_42" }
    adb.setSocketNames(noise + ["snapo_sample_42", "snapo_network_43"], deviceID: "healthy")
    let service = ToolHTTPService(adbService: adbService)
    await refresh(service, using: adb)
    try await eventually { adb.metadataProcessRequests.count == 1 && adb.toolConnectionCount == 1 }
    let pending = await service.currentApps().apps
    precondition(pending.map(\.socketName) == ["snapo_network_43"], "Undeclared custom sockets stay hidden during discovery")
    adb.setMetadataAvailable(true)
    try await eventually {
      let apps = await service.currentApps().apps
      return apps.map(\.socketName) == ["snapo_network_43", "snapo_sample_42"]
        && apps.allSatisfy { $0.compatibility == .supported && $0.isConnected }
    }
    precondition(adb.metadataProcessRequests == [[42, 43]])
    precondition(adb.toolConnectionCount == 2, "Only declared tools and known legacy kinds receive health checks")
    precondition(adb.legacyRequestCount == 0, "Unknown custom names do not trigger legacy probes")
    await refresh(service, using: adb)
    precondition(adb.metadataProcessRequests.count == 1, "Undeclared names do not invalidate package metadata")
    adb.setSocketNames(noise + ["snapo_network_43"], deviceID: "healthy")
    await refresh(service, using: adb)
    let remaining = await service.currentApps().apps
    precondition(remaining.map(\.socketName) == ["snapo_network_43"], "A cached manifest cannot keep a closed custom tool visible")
    await service.stop()

    let requestsBeforeBatches = adb.metadataProcessRequests.count
    let manyProcesses = ToolHTTPService(adbService: adbService)
    adb.setSocketNames((100 ... 164).map { "snapo_noise_\($0)" }, deviceID: "healthy")
    await refresh(manyProcesses, using: adb)
    try await eventually { adb.metadataProcessRequests.count == requestsBeforeBatches + 2 }
    let batches = Array(adb.metadataProcessRequests.suffix(2))
    precondition(batches.map(\.count) == [64, 1])
    precondition(batches.joined().elementsEqual(100 ... 164))
    let visible = await manyProcesses.currentApps().apps
    precondition(visible.isEmpty)
    await manyProcesses.stop()
    print("Manifest-backed discovery filters socket floods and batches distinct process IDs")
  }

  static func compatibilityStates() throws {
    func status(tools: [[String: Any]], errors: [[String: String]] = []) throws -> ToolCompatibility {
      let record: [String: Any] = [
        "version": 1, "pid": 42, "processIdentity": "boot:42:1", "androidUserId": 0,
        "app": ["name": "Demo", "packageName": "com.example.demo", "revision": "1", "inspectors": tools, "errors": errors]
      ]
      let manifest = try JSONDecoder().decode(ToolProcessMetadata.self, from: JSONSerialization.data(withJSONObject: record))
      var metadata = ToolMetadata()
      metadata.applyPackageMetadata(manifest, kind: .network)
      return ToolHTTPService.App(
        kind: .network, pid: 42, deviceID: "phone", deviceDisplayTitle: "Phone", socketName: "snapo_network_42", metadata: metadata
      ).compatibility
    }
    let descriptor: [String: Any] = ["id": "network", "name": "Network"]
    let missingFrontend = try status(tools: [descriptor])
    precondition(missingFrontend == .missingFrontend)
    let missingDescriptor = try status(tools: [])
    precondition(missingDescriptor == .missingDescriptor)
    let invalidDescriptor = try status(tools: [], errors: [["key": "snapo.inspector.network", "error": "Invalid XML"]])
    precondition(invalidDescriptor == .invalidDescriptor)
    let siblingError = try status(tools: [], errors: [["key": "snapo.inspector.tweaks", "error": "Invalid XML"]])
    precondition(siblingError == .missingDescriptor)
    for version in [0, 1, 2, 3, 4] {
      var value = descriptor
      value["frontend"] = ["assetPath": "frontend.zip", "hostApiVersion": version]
      let actual = try status(tools: [value])
      precondition(actual == (version == 1 ? .supported : .hostAPI(version: version)))
    }
    var pending = ToolHTTPService.App(
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
    let legacy = try await adb.legacyPluginMetadata(
      reference: ToolServerReference(deviceId: "phone", socketName: "snapo_network_42"), kind: .network, pid: 42
    )!
    func record(
      package: String = "com.example.demo",
      processName: String = "com.example.demo",
      revision: String = "1",
      kinds: [ToolID] = []
    ) throws -> ToolProcessMetadata {
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
              "frontend": ["assetPath": "frontend.zip", "hostApiVersion": 1]
            ] as [String: Any]
          }
        ]
      ]
      return try JSONDecoder().decode(ToolProcessMetadata.self, from: JSONSerialization.data(withJSONObject: value))
    }
    var metadata = ToolMetadata()
    precondition(metadata.applyLegacyMetadata(legacy, kind: .network))
    precondition(metadata.process.name == "Demo" && metadata.process.packageName == "com.example.demo")
    precondition(metadata.process.verifiedIdentity == nil && metadata.process.tools.isEmpty)
    precondition(metadata.compatibility == .legacy(protocolVersion: 1))
    let legacyConnection = try JSONSerialization.jsonObject(with: JSONEncoder().encode(
      ToolConnectionState(metadata: metadata.process)
    )) as! [String: Any]
    precondition(legacyConnection["manifest"] == nil)

    let modern = try record(kinds: [.network])
    precondition(metadata.applyPackageMetadata(modern, kind: .network))
    precondition(metadata.process.name == "Package label" && metadata.process.verifiedIdentity != nil)
    precondition(metadata.compatibility == .supported)
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
    precondition(metadata.compatibility == .missingDescriptor)

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
    let service = ToolService(adbService: adbService, deviceTracker: tracker)
    try await eventually {
      let options = await service.discoverPlugins().apps.first?.tools
      return options?.first { $0.kind == .network }?.compatibility == .legacy(protocolVersion: 1)
        && options?.first { $0.kind == .tweaks }?.compatibility == .supported
        && options?.allSatisfy(\.isConnected) == true
    }
    let app = await service.currentPlugins().apps.first!
    precondition(app.tools.count == 2)
    var selection = ToolSelection()
    selection.reconcile([app])
    precondition(selection.state.preferredKind == .tweaks, "Initial selection prefers a compatible sibling")
    selection.selectTool(app, option: app.tools[0])
    precondition(selection.state.preferredKind == .network, "Unsupported tools remain selectable")
    do {
      _ = try await service.pluginEndpoint(for: app.tools[0].server)
      fatalError("Legacy metadata must not authorize a tool endpoint")
    } catch ToolError.serverNotConnected {}
    _ = try await service.pluginEndpoint(for: app.tools[1].server)
    for _ in 0 ..< 5 {
      _ = await service.discoverPlugins()
    }
    precondition(adb.legacyRequestCount == 1, "Known legacy metadata is cached and modern siblings are not probed")
    adb.setLegacyKinds([])
    adb.replaceListeners()
    try await eventually {
      await service.discoverPlugins().apps.first?.tools.allSatisfy { $0.compatibility == .supported } == true
    }
    precondition(adb.legacyRequestCount == 1, "Replacement listeners use fresh manifests before legacy detection")
    await service.stop()
    await tracker.stopTracking()
    print("Unsupported tools remain visible and selectable beside usable siblings; listener replacement clears compatibility")
  }

  private static func refresh(_ service: ToolHTTPService, using adb: ADBClient) async {
    let device = Device(id: "healthy", model: "Phone", androidVersion: "Test", vendorModel: nil, manufacturer: nil, avdName: nil)
    let sockets = await ToolDiscovery.discover(on: [device.id], using: adb)
    await service.refresh(devices: [device], sockets: sockets, using: adb)
  }

  static func preservesMetadataAfterFailure() async throws {
    for failure: ADBClient.MetadataFailure in [.request, .record] {
      let adbService = ADBService()
      let adb = await adbService.exec()
      adb.setMetadataAvailable(true)
      adb.setSocketNames(["snapo_network_42"], deviceID: "healthy")
      let service = ToolHTTPService(adbService: adbService)
      await refresh(service, using: adb)
      try await eventually {
        let app = await service.currentApps().apps.first
        return app?.compatibility == .supported && app?.isConnected == true
      }
      let original = await service.currentApps().apps.first!
      let network = ToolServerReference(deviceId: "healthy", socketName: "snapo_network_42")
      let tweaks = ToolServerReference(deviceId: "healthy", socketName: "snapo_tweaks_42")
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
      } catch ToolError.serverNotConnected {}
      let now = ContinuousClock.now
      precondition(!failed[0].needsMetadataRead(lastAttempt: now, now: now.advanced(by: .seconds(29))))
      precondition(failed[0].needsMetadataRead(lastAttempt: now, now: now.advanced(by: .seconds(30))))
      await refresh(service, using: adb)
      precondition(adb.metadataProcessRequests.count == 2, "Failed metadata refreshes must still back off")

      adb.replaceListeners()
      await refresh(service, using: adb)
      try await eventually {
        let apps = await service.currentApps().apps
        return adb.metadataProcessRequests.count == 3 && apps.allSatisfy(\.metadataReadFailed)
      }
      let replacement = await service.currentApps().apps.first!
      precondition(replacement.metadata.process == original.metadata.process, "Retain display metadata while a replacement is unverified")
      precondition(replacement.awaitingMetadata && !replacement.isConnected && replacement.compatibility == .metadataUnavailable)
      do {
        _ = try await service.endpoint(for: network)
        fatalError("Preserved metadata cannot authorize a replacement listener after a failed read")
      } catch ToolError.serverNotConnected {}

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
    let service = ToolHTTPService(adbService: adbService)
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
    precondition(adb.metadataProcessRequests.count == 2, "Rediscovery must not wait for the failed-request cooldown")
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
