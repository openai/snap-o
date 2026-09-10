import Foundation
import SnapODeviceClient

actor NetworkInspectorService {
  private let adbService: ADBService
  private let deviceTracker: DeviceTracker
  private let httpService: InspectorHTTPService
  private var inspectorServerOrder: [InspectorServerReference] = []
  private var refreshTask: Task<Void, Never>?
  private var isStopped = false

  init(adbService: ADBService, deviceTracker: DeviceTracker) {
    self.adbService = adbService
    self.deviceTracker = deviceTracker
    httpService = InspectorHTTPService(adbService: adbService)
  }

  func discoverInspectors() async -> InspectorDiscoverySnapshot {
    await refresh()
    let applications = await httpService.currentApps()
    let endpoints = applications.map { app in
      InspectorEndpoint(
        kind: app.kind,
        reference: NetworkServerReference(deviceId: app.deviceID, socketName: app.socketName),
        deviceDisplayTitle: app.deviceDisplayTitle,
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
          AppInspectorOption(kind: endpoint.kind, server: endpoint.reference, protocolVersion: endpoint.protocolVersion)
        }
      )
    }
    let networkServers = applications.filter { $0.kind == .network }.map { app in
      NetworkInspectorServer(
        server: "\(app.deviceID):\(app.socketName)",
        deviceId: app.deviceID,
        socketName: app.socketName,
        deviceDisplayTitle: app.deviceDisplayTitle,
        displayName: app.name ?? app.packageName ?? app.socketName,
        isConnected: app.protocolVersion != nil,
        hasAppInfo: app.protocolVersion != nil,
        pid: InspectorKind.network.pid(inSocketName: app.socketName),
        protocolVersion: app.protocolVersion,
        isProtocolNewerThanSupported: app.protocolVersion.map { $0 > SnapONetworkProtocol.supportedVersion } ?? false,
        isProtocolOlderThanSupported: app.protocolVersion.map { $0 < SnapONetworkProtocol.supportedVersion } ?? false,
        appIconBase64: app.appIconBase64,
        packageName: app.packageName,
        appName: app.name,
        instanceId: app.instanceID
      )
    }
    return InspectorDiscoverySnapshot(apps: orderedInspectorApps(apps), networkServers: networkServers)
  }

  func openApp(_ input: OpenAppInput) async throws {
    let adb = await adbService.exec()
    try await adb.openApp(deviceID: input.deviceId, packageName: input.packageName, androidUserID: input.androidUserId)
  }

  func inspectorEndpoint(for reference: InspectorServerReference) async throws -> InspectorHTTPService.Endpoint {
    try await httpService.endpoint(for: reference)
  }

  func stop() async {
    guard !isStopped else { return }
    isStopped = true
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
    let previousOrder = Dictionary(
      uniqueKeysWithValues: inspectorServerOrder.enumerated().map { ($0.element, $0.offset) }
    )
    let orderedApps = apps.sorted { first, second in
      let firstOrder = first.inspectors.compactMap { previousOrder[$0.server] }.min() ?? -1
      let secondOrder = second.inspectors.compactMap { previousOrder[$0.server] }.min() ?? -1

      if firstOrder != secondOrder {
        return firstOrder < secondOrder
      }
      if first.deviceId != second.deviceId {
        return first.deviceId < second.deviceId
      }
      return first.id < second.id
    }
    inspectorServerOrder = orderedApps.flatMap { $0.inspectors.map(\.server) }
    return orderedApps
  }
}
