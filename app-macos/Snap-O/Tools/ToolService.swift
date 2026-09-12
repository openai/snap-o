import Foundation

actor ToolService {
  private let adbService: ADBService
  private let deviceTracker: DeviceTracker
  private let httpService: ToolHTTPService
  private var toolAppOrder: [String: Int] = [:]
  private var refreshTask: Task<Void, Never>?
  private var isStopped = false
  private var frontends: [(key: [String], bundle: ToolFrontendBundle)] = []

  init(adbService: ADBService, deviceTracker: DeviceTracker) {
    self.adbService = adbService
    self.deviceTracker = deviceTracker
    httpService = ToolHTTPService(adbService: adbService)
  }

  func discoverPlugins() async -> ToolDiscoverySnapshot {
    await refresh()
    return await currentPlugins()
  }

  func changes() async -> AsyncStream<Void> {
    await httpService.changes()
  }

  func currentPlugins() async -> ToolDiscoverySnapshot {
    let snapshot = await httpService.currentApps()
    let applications = snapshot.apps
    let appsByServer = Dictionary(uniqueKeysWithValues: applications.map {
      (ToolServerReference(deviceId: $0.deviceID, socketName: $0.socketName), $0)
    })
    let endpoints = applications.map { app in
      ToolEndpoint(
        kind: app.kind,
        reference: ToolServerReference(deviceId: app.deviceID, socketName: app.socketName),
        deviceDisplayTitle: app.deviceDisplayTitle,
        pid: app.pid,
        metadata: ToolAppMetadata(
          appName: app.name,
          processName: app.processName,
          packageName: app.packageName,
          androidUserID: app.androidUserID,
          appIconBase64: app.appIconBase64
        )
      )
    }
    let apps = ToolDiscovery.processes(from: endpoints).map { process in
      let candidates = process.tools.compactMap { appsByServer[$0.reference]?.metadata.process }
      var metadata = candidates.first { $0.verifiedIdentity != nil } ?? candidates.first ?? ToolMetadata.Process()
      metadata.name = process.metadata.appName
      metadata.packageName = process.metadata.packageName
      metadata.processName = process.metadata.processName ?? process.metadata.packageNameHint
      metadata.iconBase64 = process.metadata.appIconBase64
      return InspectableApp(
        id: process.id,
        pid: process.pid,
        deviceId: process.deviceId,
        deviceDisplayTitle: process.deviceDisplayTitle,
        tools: process.tools.map { endpoint in
          AppToolOption(
            kind: endpoint.kind,
            server: endpoint.reference,
            isConnected: appsByServer[endpoint.reference]?.isConnected == true,
            name: appsByServer[endpoint.reference]?.descriptor?.name ?? endpoint.kind.rawValue,
            iconBase64: appsByServer[endpoint.reference]?.descriptor?.iconBase64,
            compatibility: appsByServer[endpoint.reference]?.compatibility ?? .unknown
          )
        },
        metadata: metadata
      )
    }
    return ToolDiscoverySnapshot(apps: orderedToolApps(apps), revision: snapshot.revision)
  }

  func openApp(_ input: OpenAppInput) async throws {
    let adb = await adbService.exec()
    try await adb.openApp(deviceID: input.deviceId, packageName: input.packageName, androidUserID: input.androidUserId)
  }

  func pluginEndpoint(
    for reference: ToolServerReference, ownerID: UUID? = nil,
    invalidated: (@MainActor @Sendable () async -> Void)? = nil
  ) async throws -> ToolHTTPService.Endpoint {
    try await httpService.endpoint(for: reference, ownerID: ownerID, invalidated: invalidated)
  }

  func releasePluginEndpoint(ownerID: UUID) async {
    await httpService.releaseEndpoint(ownerID: ownerID)
  }

  func pluginFrontend(
    for reference: ToolServerReference, identity: ToolProcessIdentity, tool: ToolDescriptor
  ) async throws -> ToolFrontendBundle {
    guard let frontend = tool.frontend,
          frontend.hostApiVersion == 2 else { throw ToolError.frontendUnavailable }
    let key = [
      reference.deviceId,
      String(identity.androidUserId),
      identity.packageName,
      identity.revision,
      tool.id.rawValue,
      frontend.assetPath
    ]
    if let index = frontends.firstIndex(where: { $0.key == key }) {
      let cached = frontends.remove(at: index)
      frontends.append(cached)
      return cached.bundle
    }
    let adb = await adbService.exec()
    let helper = (Bundle.main.resourceURL ?? Bundle.main.bundleURL.appending(path: "Contents/Resources"))
      .appending(path: "snapo-tool-reader.jar")
    let bundle = try await adb.pluginFrontend(
      deviceID: reference.deviceId, socketName: reference.socketName, identity: identity, tool: tool, helperURL: helper
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
    let sockets = await ToolDiscovery.discover(on: devices.map(\.id), using: adb)
    guard !Task.isCancelled, !isStopped else { return }
    await httpService.refresh(devices: devices, sockets: sockets, using: adb)
  }

  private func orderedToolApps(_ apps: [InspectableApp]) -> [InspectableApp] {
    for app in apps where toolAppOrder[app.id] == nil {
      toolAppOrder[app.id] = toolAppOrder.count
    }
    return apps.sorted {
      toolAppOrder[$0.id, default: Int.max] < toolAppOrder[$1.id, default: Int.max]
    }
  }
}
