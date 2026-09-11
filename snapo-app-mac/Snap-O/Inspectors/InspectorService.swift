import Foundation
import SnapODeviceClient

actor InspectorService {
  private let adbService: ADBService
  private let deviceTracker: DeviceTracker
  private let httpService: InspectorHTTPService
  private var inspectorAppOrder: [String: Int] = [:]
  private var refreshTask: Task<Void, Never>?
  private var isStopped = false
  private var frontends: [(key: [String], bundle: InspectorFrontendBundle)] = []

  init(adbService: ADBService, deviceTracker: DeviceTracker) {
    self.adbService = adbService
    self.deviceTracker = deviceTracker
    httpService = InspectorHTTPService(adbService: adbService)
  }

  func discoverInspectors() async -> InspectorDiscoverySnapshot {
    await refresh()
    return await currentInspectors()
  }

  func changes() async -> AsyncStream<Void> {
    await httpService.changes()
  }

  func currentInspectors() async -> InspectorDiscoverySnapshot {
    let snapshot = await httpService.currentApps()
    let applications = snapshot.apps
    let connectedServers = Set(applications.filter(\.isConnected).map {
      InspectorServerReference(deviceId: $0.deviceID, socketName: $0.socketName)
    })
    let manifests = Dictionary(uniqueKeysWithValues: applications.map {
      (InspectorServerReference(deviceId: $0.deviceID, socketName: $0.socketName), $0)
    })
    let endpoints = applications.map { app in
      InspectorEndpoint(
        kind: app.kind,
        reference: InspectorServerReference(deviceId: app.deviceID, socketName: app.socketName),
        deviceDisplayTitle: app.deviceDisplayTitle,
        pid: app.pid,
        protocolVersion: app.protocolVersion,
        metadata: InspectorAppMetadata(
          appName: app.name,
          processName: app.processName,
          packageName: app.packageName,
          androidUserID: app.androidUserID,
          appIconBase64: app.appIconBase64
        )
      )
    }
    let apps = InspectorDiscovery.processes(from: endpoints).map { process in
      InspectableApp(
        id: process.id,
        name: process.name,
        packageName: process.metadata.packageName,
        processName: process.metadata.processName ?? process.metadata.packageNameHint,
        androidUserId: process.metadata.androidUserID,
        deviceId: process.deviceId,
        deviceDisplayTitle: process.deviceDisplayTitle,
        appIconBase64: process.metadata.appIconBase64,
        inspectors: process.inspectors.map { endpoint in
          AppInspectorOption(
            kind: endpoint.kind,
            server: endpoint.reference,
            protocolVersion: endpoint.protocolVersion,
            isConnected: connectedServers.contains(endpoint.reference),
            name: manifests[endpoint.reference]?.descriptor?.name ?? endpoint.kind.rawValue,
            iconBase64: manifests[endpoint.reference]?.descriptor?.iconBase64
          )
        },
        manifest: process.inspectors.compactMap { manifests[$0.reference]?.manifest }.first
      )
    }
    return InspectorDiscoverySnapshot(apps: orderedInspectorApps(apps), revision: snapshot.revision)
  }

  func openApp(_ input: OpenAppInput) async throws {
    let adb = await adbService.exec()
    try await adb.openApp(deviceID: input.deviceId, packageName: input.packageName, androidUserID: input.androidUserId)
  }

  func inspectorEndpoint(
    for reference: InspectorServerReference, ownerID: UUID? = nil,
    invalidated: (@MainActor @Sendable () async -> Void)? = nil
  ) async throws -> InspectorHTTPService.Endpoint {
    try await httpService.endpoint(for: reference, ownerID: ownerID, invalidated: invalidated)
  }

  func releaseInspectorEndpoint(ownerID: UUID) async {
    await httpService.releaseEndpoint(ownerID: ownerID)
  }

  func inspectorFrontend(
    for reference: InspectorServerReference, manifest: InspectorProcessMetadata, inspector: InspectorDescriptor
  ) async throws -> InspectorFrontendBundle {
    guard let app = manifest.app, let user = manifest.androidUserId, let frontend = inspector.frontend,
          frontend.hostApiVersion == 1 else { throw InspectorError.frontendUnavailable }
    let key = [reference.deviceId, String(user), app.packageName, app.revision, inspector.id.rawValue, frontend.assetPath]
    if let index = frontends.firstIndex(where: { $0.key == key }) {
      let cached = frontends.remove(at: index)
      frontends.append(cached)
      return cached.bundle
    }
    let adb = await adbService.exec()
    let helper = (Bundle.main.resourceURL ?? Bundle.main.bundleURL.appending(path: "Contents/Resources"))
      .appending(path: "snapo-discovery.jar")
    let bundle = try await adb.inspectorFrontend(
      deviceID: reference.deviceId, socketName: reference.socketName, manifest: manifest, inspector: inspector, helperURL: helper
    )
    guard !Task.isCancelled, !isStopped else { throw CancellationError() }
    frontends.removeAll { $0.key == key }
    while frontends.count >= 4 {
      frontends.removeFirst()
    }
    frontends.append((key, bundle))
    return bundle
  }

  func stop() async {
    guard !isStopped else { return }
    isStopped = true
    frontends.removeAll()
    refreshTask?.cancel()
    await refreshTask?.value
    refreshTask = nil
    await httpService.stop()
  }

  private func refresh() async {
    guard !isStopped else { return }
    if let refreshTask {
      await refreshTask.value
      return
    }
    let task = Task { await refreshNow() }
    refreshTask = task
    await task.value
    refreshTask = nil
  }

  private func refreshNow() async {
    let devices = await deviceTracker.latestDevices
    let adb = await adbService.exec()
    let sockets = await InspectorDiscovery.discover(on: devices.map(\.id), using: adb)
    guard !Task.isCancelled, !isStopped else { return }
    await httpService.refresh(devices: devices, sockets: sockets, using: adb)
  }

  private func orderedInspectorApps(_ apps: [InspectableApp]) -> [InspectableApp] {
    for app in apps where inspectorAppOrder[app.id] == nil {
      inspectorAppOrder[app.id] = inspectorAppOrder.count
    }
    return apps.sorted {
      inspectorAppOrder[$0.id, default: Int.max] < inspectorAppOrder[$1.id, default: Int.max]
    }
  }
}
