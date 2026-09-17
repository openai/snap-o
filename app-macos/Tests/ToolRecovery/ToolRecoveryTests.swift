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
    try await reconnectsAfterCooldown()
    try await cachesOnlyTheSameProcess()
    try await retriesFailedDeviceProperties()
    try await refreshesSiblingDescriptors()
    try await filtersSocketFloods()
    try await mixedCompatibility()
    try await preservesMetadataAfterFailure()
    try await restartsCanceledLegacyProbe()
  }

  static func reconnectsAfterCooldown() async throws {
    let adbService = ADBService()
    let adb = await adbService.exec()
    let clock = RecoveryClock()
    let service = ToolHTTPService(adbService: adbService) { clock.now }
    var published: [ToolHTTPService.App] = []
    let changes = await service.changes()
    let observer = Task {
      for await _ in changes {
        published = await service.currentApps().apps
      }
    }
    defer { observer.cancel() }
    await refresh(service, using: adb, devices: ["frozen", "healthy"])
    try await eventually {
      published.count == 4 && published.filter { $0.deviceID == "healthy" }.allSatisfy(\.isConnected)
        && adb.failedToolConnectionCount == 2
    }
    let network = ToolServerReference(deviceId: "frozen", socketName: "snapo_network_42")
    let healthy = ToolServerReference(deviceId: "healthy", socketName: "snapo_network_42")
    do {
      _ = try await service.endpoint(for: healthy)
      fatalError("HTTP readiness alone must not authorize an endpoint")
    } catch ToolError.serverNotConnected {}

    adb.setMetadataAvailable(true)
    try await eventually { published.allSatisfy { $0.name == "Demo" && $0.compatibility == .supported } }
    precondition(adb.scannedDeviceIDs.count == 2, "Metadata must publish without another device scan")
    precondition(published.filter { $0.deviceID == "frozen" }.allSatisfy { !$0.isConnected })
    _ = try await service.endpoint(for: healthy)
    adb.unfreeze()
    clock.advance(by: .milliseconds(2999))
    let healthyAttempts = adb.connectionAttempts(to: "healthy")
    await refresh(service, using: adb, devices: ["frozen", "healthy"])
    // Wait for this refresh to reach the transport before checking the blocked sockets.
    try await eventually { adb.connectionAttempts(to: "healthy") == healthyAttempts + 2 }
    precondition(adb.connectionAttempts(to: "frozen") == 2, "Cooldown must suppress new connections")
    clock.advance(by: .milliseconds(1))
    await refresh(service, using: adb, devices: ["frozen", "healthy"])
    try await eventually { published.allSatisfy(\.isConnected) }
    _ = try await service.endpoint(for: network)
    let metadata = published.map(\.metadata)
    adb.disconnectNetwork()
    await refresh(service, using: adb, devices: ["frozen", "healthy"])
    try await eventually { published.first?.isConnected == false }
    precondition(published.dropFirst().allSatisfy(\.isConnected), "A failed socket must not disconnect its siblings")
    precondition(published.map(\.metadata) == metadata)
    await service.stop()
    do {
      _ = try await service.endpoint(for: healthy)
      fatalError("Stopped services must reject endpoints")
    } catch ToolError.serverNotConnected {}
    print("Connection and metadata changes publish independently; failed sockets retry only after cooldown")
  }

  static func cachesOnlyTheSameProcess() async throws {
    let adbService = ADBService()
    let adb = await adbService.exec()
    adb.setMetadataAvailable(true)
    let tracker = DeviceTracker(adbService: adbService)
    await tracker.startTracking()
    adb.emitDevices("healthy device transport_id:1\nother device transport_id:2")
    try await eventually { await tracker.latestDevices.count == 2 }
    let service = ToolService(adbService: adbService, deviceTracker: tracker)
    _ = await service.discoverPlugins()
    try await eventually { await service.currentPlugins().apps.allSatisfy { $0.appIconBase64 != nil } }
    let original = await service.currentPlugins().apps
    precondition(original.count == 2)
    adb.setSocketNames([], deviceID: "healthy")
    let missing = await service.discoverPlugins().apps
    precondition(missing.map(\.deviceId) == ["other"])
    adb.setMetadataAvailable(false)
    adb.setSocketNames(["snapo_network_42"], deviceID: "healthy")
    let returned = await service.discoverPlugins().apps
    precondition(returned.map(\.id) == original.map(\.id), "Rediscovery preserves row order")
    precondition(returned[0].metadata == original[0].metadata)
    precondition(returned[0].tools.count == 1 && returned[0].tools[0].compatibility == .supported)
    adb.setSocketNames(["snapo_network_43"], deviceID: "healthy")
    let replacement = await service.discoverPlugins().apps.last!
    precondition(replacement.id != original[0].id && replacement.processName == "com.example.demo:worker")
    precondition(replacement.appIconBase64 == nil && replacement.tools[0].compatibility != .supported)
    await service.stop()
    let stopped = await service.discoverPlugins().apps
    precondition(stopped.isEmpty)

    adb.setSocketNames(["snapo_network_42"], deviceID: "healthy")
    let restarted = ToolService(adbService: adbService, deviceTracker: tracker)
    let fresh = await restarted.discoverPlugins().apps
    precondition(fresh.allSatisfy { $0.appIconBase64 == nil }, "Metadata is not shared across service instances")
    adb.setMetadataAvailable(true)
    try await eventually {
      await restarted.currentPlugins().apps.allSatisfy { $0.tools.allSatisfy { $0.isConnected && $0.compatibility == .supported } }
    }
    _ = try await restarted.pluginEndpoint(for: ToolServerReference(deviceId: "healthy", socketName: "snapo_network_42"))
    await restarted.stop()
    await tracker.stopTracking()
    print("Rediscovery retains same-process metadata and order; replacement processes and new services start fresh")
  }

  static func retriesFailedDeviceProperties() async throws {
    let adbService = ADBService()
    let adb = await adbService.exec()
    let tracker = DeviceTracker(adbService: adbService)
    await tracker.startTracking()
    adb.emitDevices("healthy device transport_id:1\nstalled device transport_id:2")
    try await eventually { await tracker.latestDevices.map(\.id) == ["healthy"] }
    adb.recoverProperties()
    try await eventually { await tracker.latestDevices.map(\.id) == ["healthy", "stalled"] }
    await tracker.stopTracking()
    print("Failed device properties recover without another tracking event")
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
    print("Legacy tools remain visible but cannot authorize endpoints; listener replacement clears compatibility")
  }

  private static func refresh(_ service: ToolHTTPService, using adb: ADBClient, devices ids: [String] = ["healthy"]) async {
    let devices = ids.map { Device(id: $0, model: "Phone", androidVersion: "Test", vendorModel: nil, manufacturer: nil, avdName: nil) }
    let sockets = await ToolDiscovery.discover(on: ids, using: adb)
    await service.refresh(devices: devices, sockets: sockets, using: adb)
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

private final class RecoveryClock: @unchecked Sendable {
  private let lock = NSLock()
  private var instant = ContinuousClock.now
  var now: ContinuousClock.Instant {
    lock.withLock { instant }
  }

  func advance(by duration: Duration) {
    lock.withLock { instant = instant.advanced(by: duration) }
  }
}
