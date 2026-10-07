import Dependencies
import Foundation
import NIOHTTP1

actor ToolHTTPService {
  struct App {
    let kind: ToolID
    let pid: Int
    let deviceID: String
    let target: DeviceTarget
    var deviceDisplayTitle: String
    let socketName: String
    var metadata = ToolMetadata()
    var socketInode: String?
    var awaitingMetadata = false
    var isConnected = false
    var metadataReadFailed = false
    var checkingLegacy = false

    var compatibility: ToolCompatibility {
      if awaitingMetadata { return metadataReadFailed ? .metadataUnavailable : .unknown }
      if checkingLegacy { return .unknown }
      if metadata.compatibility != .unknown { return metadata.compatibility }
      return metadataReadFailed ? .metadataUnavailable : .unknown
    }

    var name: String? {
      metadata.process.name
    }

    var packageName: String? {
      metadata.process.packageName
    }

    var processName: String? {
      metadata.process.processName
    }

    var androidUserID: Int? {
      metadata.process.verifiedIdentity?.androidUserId
    }

    var appIconBase64: String? {
      metadata.process.iconBase64
    }

    var descriptor: ToolDescriptor? {
      metadata.descriptor(for: kind)
    }

    var supportsLegacyDiscovery: Bool {
      kind.rawValue == "network" || kind.rawValue == "tweaks"
    }

    var isVisible: Bool {
      descriptor != nil || metadata.compatibility == .invalidDescriptor || supportsLegacyDiscovery
    }

    func needsMetadataRead<Instant: InstantProtocol>(lastAttempt: Instant?, now: Instant) -> Bool where Instant.Duration == Duration {
      guard metadata.process.verifiedIdentity == nil || awaitingMetadata || metadataReadFailed
        || (supportsLegacyDiscovery && metadata.needsLegacyProbe)
      else { return false }
      guard let lastAttempt else { return true }
      return lastAttempt.duration(to: now) >= .seconds(30)
    }
  }

  private struct Connection {
    let id: UUID
    let reference: ToolServerReference
    let target: DeviceTarget
    var isReady = false
    var healthTask: Task<Void, Never>?
  }

  private static let retryCooldown: Duration = .seconds(3)

  private let clock: AnyClock<Duration>
  private let adbService: ADBService
  private var connections: [String: Connection] = [:]
  private var knownApps: [String: App] = [:]
  private var discoveredKeys: Set<String> = []
  private var retryAfter: [String: AnyClock<Duration>.Instant] = [:]
  private var metadataTasks: [DeviceTarget: Task<Void, Never>] = [:]
  private var legacyTasks: [String: Task<Void, Never>] = [:]
  private var metadataReadAt: [String: AnyClock<Duration>.Instant] = [:]
  private let helperURL: URL
  private var observers: [UUID: AsyncStream<Void>.Continuation] = [:]
  private var snapshotRevision: UInt64 = 0
  private var isStopped = false
  private var pendingWork: [UUID: Task<Void, Never>] = [:]
  private var stopTask: Task<Void, Never>?

  init(
    adbService: ADBService, helperURL: URL? = nil
  ) {
    @Dependency(\.continuousClock)
    var clock
    self.clock = AnyClock(clock)
    self.adbService = adbService
    self.helperURL = helperURL ?? (Bundle.main.resourceURL ?? Bundle.main.bundleURL.appending(path: "Contents/Resources"))
      .appending(path: "snapo-tool-reader.jar")
  }

  func currentApps() -> (revision: UInt64, apps: [App]) {
    snapshotRevision += 1
    let apps = discoveredKeys.compactMap { key -> App? in
      guard var app = knownApps[key], app.isVisible else { return nil }
      app.isConnected = app.target.isValid && connections[key]?.isReady == true && !app.awaitingMetadata
      return app
    }.sorted {
      if $0.deviceID != $1.deviceID { return $0.deviceID < $1.deviceID }
      return $0.socketName < $1.socketName
    }
    return (snapshotRevision, apps)
  }

  func changes() -> AsyncStream<Void> {
    let id = UUID()
    let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    guard !isStopped else {
      continuation.finish()
      return stream
    }
    observers[id] = continuation
    continuation.onTermination = { [weak self] _ in
      Task { await self?.removeObserver(id) }
    }
    continuation.yield(())
    return stream
  }

  private func removeObserver(_ id: UUID) {
    observers[id] = nil
  }

  private func notifyChange() {
    for observer in observers.values {
      observer.yield(())
    }
  }

  func refresh(devices: [Device], sockets: [DiscoveredPluginSocket], using adb: ADBClient) async {
    guard !isStopped else { return }
    let devicesByID = Dictionary(uniqueKeysWithValues: devices.map { ($0.id, $0) })
    let activeTargets = Set(devices.compactMap(\.connection))
    for target in metadataTasks.keys where !activeTargets.contains(target) {
      metadataTasks.removeValue(forKey: target)?.cancel()
    }
    let activeKeys = Set(sockets.filter { devicesByID[$0.reference.deviceId]?.connection?.isValid == true }.map(\.reference.key))
    discoveredKeys = activeKeys
    // Socket discovery owns list membership; temporary HTTP failures only change connectivity.
    for socket in sockets {
      let reference = socket.reference
      guard let device = devicesByID[reference.deviceId], let target = device.connection, target.isValid else { continue }
      if var previous = knownApps[reference.key], previous.target != target || previous.socketInode != socket.inode {
        metadataReadAt[reference.key] = nil
        retryAfter[reference.key] = nil
        legacyTasks.removeValue(forKey: reference.key)?.cancel()
        previous.metadata.invalidateCompatibility()
        previous.checkingLegacy = false
        previous.metadataReadFailed = false
        if let connection = connections.removeValue(forKey: reference.key) {
          connection.healthTask?.cancel()
        }
        if previous.target == target, let processName = socket.processName, processName == previous.processName {
          // Keep display metadata, but verify the process before using a replacement listener.
          previous.socketInode = socket.inode
          previous.awaitingMetadata = true
          knownApps[reference.key] = previous
        } else {
          knownApps[reference.key] = nil
        }
      }
      if knownApps[reference.key] == nil {
        knownApps[reference.key] = App(
          kind: socket.kind, pid: socket.pid, deviceID: reference.deviceId, target: target,
          deviceDisplayTitle: device.displayTitle, socketName: reference.socketName, socketInode: socket.inode
        )
      }
      knownApps[reference.key]?.deviceDisplayTitle = device.displayTitle
      if let processName = socket.processName {
        knownApps[reference.key]?.metadata.updateProcessName(processName)
      }
    }
    populateMetadata(sockets: sockets.filter { activeKeys.contains($0.reference.key) }, using: adb)
    for key in legacyTasks.keys where !activeKeys.contains(key) {
      legacyTasks.removeValue(forKey: key)?.cancel()
      knownApps[key]?.checkingLegacy = false
      metadataReadAt[key] = nil
    }
    retryAfter = retryAfter.filter { activeKeys.contains($0.key) && $0.value > clock.now }

    for socket in sockets {
      let reference = socket.reference
      guard devicesByID[reference.deviceId] != nil, !Task.isCancelled, !isStopped,
            knownApps[reference.key]?.isVisible == true, retryAfter[reference.key] == nil else { continue }
      if connections[reference.key] != nil {
        checkHealth(for: reference.key)
      } else {
        connect(reference: reference)
      }
    }

    guard !Task.isCancelled, !isStopped else { return }
    for key in connections.keys.filter({ !activeKeys.contains($0) }) {
      guard let connection = connections.removeValue(forKey: key) else { continue }
      connection.healthTask?.cancel()
    }
    notifyChange()
  }

  struct Endpoint {
    let id: UUID
    let reference: ToolServerReference
    let adb: ADBClient
    let target: DeviceTarget
  }

  func target(for reference: ToolServerReference) throws -> DeviceTarget {
    guard discoveredKeys.contains(reference.key), let app = knownApps[reference.key], app.target.isValid else {
      throw ToolError.serverNotConnected(reference)
    }
    return app.target
  }

  func endpoint(for reference: ToolServerReference) async throws -> Endpoint {
    let connection = try connection(for: reference)
    let adb = await adbService.exec().bound(to: connection.target)
    _ = try connection.target.requireTransport(for: connection.target.serial)
    return Endpoint(id: connection.id, reference: reference, adb: adb, target: connection.target)
  }

  func stop() async {
    if let stopTask {
      await stopTask.value
      return
    }
    isStopped = true
    let work = Array(pendingWork.values)
    for task in work {
      task.cancel()
    }
    for observer in observers.values {
      observer.finish()
    }
    observers.removeAll()
    metadataTasks.removeAll()
    legacyTasks.removeAll()
    metadataReadAt.removeAll()
    connections.removeAll()
    knownApps.removeAll()
    discoveredKeys.removeAll()
    retryAfter.removeAll()
    let task = Task {
      for task in work {
        await task.value
      }
    }
    stopTask = task
    await task.value
  }

  /// Lookup maps describe current work; this retains superseded work until it finishes.
  private func startWork(_ operation: @escaping @Sendable () async -> Void) -> Task<Void, Never> {
    let id = UUID()
    let task = Task {
      await operation()
      pendingWork[id] = nil
    }
    pendingWork[id] = task
    return task
  }

  private func connect(reference: ToolServerReference) {
    let key = reference.key
    guard !Task.isCancelled, !isStopped, connections[key] == nil, retryAfter[key] == nil else {
      return
    }

    guard let app = knownApps[key], app.isVisible, app.target.isValid else { return }
    connections[key] = Connection(id: UUID(), reference: reference, target: app.target)
    checkHealth(for: key)
  }

  private func populateMetadata(sockets: [DiscoveredPluginSocket], using adb: ADBClient) {
    for (_, sockets) in Dictionary(grouping: sockets, by: { $0.reference.deviceId }) {
      guard let target = sockets.first.flatMap({ knownApps[$0.reference.key]?.target }),
            target.isValid, metadataTasks[target] == nil else { continue }
      let pendingPIDs = Set(sockets.filter {
        guard let app = knownApps[$0.reference.key] else { return true }
        return app.needsMetadataRead(lastAttempt: metadataReadAt[$0.reference.key], now: clock.now)
      }.map(\.pid))
      let pending = sockets.filter { pendingPIDs.contains($0.pid) }
      guard !pending.isEmpty else { continue }
      metadataTasks[target] = startWork { [weak self] in
        await self?.loadMetadata(target: target, sockets: pending, using: adb.bound(to: target))
      }
    }
  }

  private func loadMetadata(target: DeviceTarget, sockets: [DiscoveredPluginSocket], using adb: ADBClient) async {
    let deviceID = target.serial
    defer {
      if !Task.isCancelled { metadataTasks[target] = nil }
    }
    let socketsByPID = Dictionary(grouping: sockets, by: \.pid)
    let pids = socketsByPID.keys.sorted()
    for offset in stride(from: 0, to: pids.count, by: 64) {
      let batch = Array(pids[offset ..< min(offset + 64, pids.count)])
      let records = try? await adb.pluginMetadata(
        deviceID: deviceID, processIDs: batch, helperURL: helperURL
      )
      guard !Task.isCancelled, !isStopped, target.isValid else { return }
      var changed = false
      for socket in batch.flatMap({ socketsByPID[$0] ?? [] }) {
        let key = socket.reference.key
        guard var app = knownApps[key], app.target == target, app.socketInode == socket.inode,
              discoveredKeys.contains(key) else { continue }
        metadataReadAt[key] = clock.now
        let hadResult = app.metadata.process.verifiedIdentity != nil || app.metadata.compatibility != .unknown || app.metadataReadFailed
        let record = records?.first { $0.pid == socket.pid }
        let updated = record.map { app.metadata.applyPackageMetadata($0, kind: app.kind) } ?? false
        app.metadataReadFailed = !updated
        if updated { app.awaitingMetadata = false }
        let needsLegacy = app.supportsLegacyDiscovery && app.metadata.needsLegacyProbe
        app.checkingLegacy = needsLegacy && !hadResult
        knownApps[key] = app
        if !app.isVisible {
          connections.removeValue(forKey: key)?.healthTask?.cancel()
        } else {
          connect(reference: socket.reference)
        }
        if needsLegacy, legacyTasks[key] == nil {
          legacyTasks[key] = startWork { [weak self] in
            await self?.loadLegacyMetadata(socket: socket, target: target, using: adb)
          }
        }
        changed = true
      }
      if changed { notifyChange() }
    }
  }

  private func loadLegacyMetadata(socket: DiscoveredPluginSocket, target: DeviceTarget, using adb: ADBClient) async {
    let key = socket.reference.key
    let metadata = try? await adb.legacyPluginMetadata(
      deviceID: target.serial, socketName: socket.reference.socketName, kind: socket.kind, pid: socket.pid
    )
    guard !Task.isCancelled, !isStopped, target.isValid, discoveredKeys.contains(key),
          var app = knownApps[key], app.target == target, app.socketInode == socket.inode else { return }
    legacyTasks[key] = nil
    app.checkingLegacy = false
    if let metadata { app.metadata.applyLegacyMetadata(metadata, kind: app.kind) }
    knownApps[key] = app
    notifyChange()
  }

  private func checkHealth(for key: String) {
    guard let app = knownApps[key], app.isVisible, !app.metadata.isLegacy else { return }
    guard let connection = connections[key], connection.healthTask == nil else { return }
    connections[key]?.healthTask = startWork { [weak self] in
      await self?.loadHealth(for: key, connectionID: connection.id)
    }
  }

  private func loadHealth(for key: String, connectionID: UUID) async {
    defer {
      if connections[key]?.id == connectionID { connections[key]?.healthTask = nil }
    }
    guard let connection = connections[key], connection.id == connectionID else { return }
    var request = URLRequest(url: ToolURL.api)
    request.httpMethod = "OPTIONS"
    do {
      let adb = await adbService.exec().bound(to: connection.target)
      let input = try ToolHTTPRequestInput(request: request)
      let operation = ToolHTTPRequestOperation(input: input, requestTimeout: .seconds(2)) {
        try await adb.openLocalAbstract(deviceID: connection.target.serial, abstractSocket: connection.reference.socketName)
      }
      try await operation.run(onResponse: { response in
        guard (200 ... 299).contains(response.status.code) else { throw ToolHTTPTransportError.invalidResponse }
      }, onData: { _ in })
      guard !Task.isCancelled, connections[key]?.id == connectionID else { return }
      let changed = connections[key]?.isReady != true
      connections[key]?.isReady = true
      if changed { notifyChange() }
    } catch {
      if connections[key]?.id == connectionID {
        retryAfter[key] = clock.now.advanced(by: Self.retryCooldown)
        connections.removeValue(forKey: key)
        notifyChange()
      }
    }
  }

  private func connection(for reference: ToolServerReference) throws -> Connection {
    guard let connection = connections[reference.key], connection.isReady, connection.target.isValid,
          let app = knownApps[reference.key], !app.awaitingMetadata, let descriptor = app.descriptor,
          descriptor.frontend?.isHostAPICompatible ?? true else {
      throw ToolError.serverNotConnected(reference)
    }
    return connection
  }
}
