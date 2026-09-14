import Foundation
import NIOHTTP1

actor ToolHTTPService {
  struct App {
    let kind: ToolID
    let pid: Int
    let deviceID: String
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

    func needsMetadataRead(lastAttempt: ContinuousClock.Instant?, now: ContinuousClock.Instant) -> Bool {
      guard metadata.process.verifiedIdentity == nil || awaitingMetadata || metadataReadFailed || metadata.needsLegacyProbe
      else { return false }
      guard let lastAttempt else { return true }
      return lastAttempt.duration(to: now) >= .seconds(30)
    }
  }

  private struct Connection {
    let id: UUID
    let reference: ToolServerReference
    var isReady = false
    var healthTask: Task<Void, Never>?
  }

  private static let retryCooldown: Duration = .seconds(3)

  private let adbService: ADBService
  private var connections: [String: Connection] = [:]
  private var knownApps: [String: App] = [:]
  private var discoveredKeys: Set<String> = []
  private var retryAfter: [String: ContinuousClock.Instant] = [:]
  private var metadataTasks: [String: Task<Void, Never>] = [:]
  private var legacyTasks: [String: Task<Void, Never>] = [:]
  private var metadataReadAt: [String: ContinuousClock.Instant] = [:]
  private let helperURL: URL
  private var observers: [UUID: AsyncStream<Void>.Continuation] = [:]
  private var snapshotRevision: UInt64 = 0
  private var isStopped = false

  init(adbService: ADBService, helperURL: URL? = nil) {
    self.adbService = adbService
    self.helperURL = helperURL ?? (Bundle.main.resourceURL ?? Bundle.main.bundleURL.appending(path: "Contents/Resources"))
      .appending(path: "snapo-tool-reader.jar")
  }

  func currentApps() -> (revision: UInt64, apps: [App]) {
    snapshotRevision += 1
    let apps = discoveredKeys.compactMap { key -> App? in
      guard var app = knownApps[key] else { return nil }
      app.isConnected = connections[key]?.isReady == true && !app.awaitingMetadata
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
    let activeKeys = Set(sockets.filter { devicesByID[$0.reference.deviceId] != nil }.map(\.reference.key))
    discoveredKeys = activeKeys
    // Socket discovery owns list membership; temporary HTTP failures only change connectivity.
    for socket in sockets {
      let reference = socket.reference
      guard let device = devicesByID[reference.deviceId] else { continue }
      if var previous = knownApps[reference.key], previous.socketInode != socket.inode {
        metadataReadAt[reference.key] = nil
        legacyTasks.removeValue(forKey: reference.key)?.cancel()
        previous.metadata.invalidateCompatibility()
        previous.checkingLegacy = false
        previous.metadataReadFailed = false
        if let connection = connections.removeValue(forKey: reference.key) {
          connection.healthTask?.cancel()
        }
        if let processName = socket.processName, processName == previous.processName {
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
          kind: socket.kind, pid: socket.pid, deviceID: reference.deviceId,
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
    retryAfter = retryAfter.filter { activeKeys.contains($0.key) && $0.value > .now }

    await withTaskGroup(of: Void.self) { group in
      for socket in sockets {
        let reference = socket.reference
        guard devicesByID[reference.deviceId] != nil, !Task.isCancelled, !isStopped else { continue }
        let key = reference.key
        guard retryAfter[key] == nil else { continue }
        if connections[key] != nil {
          checkHealth(for: key)
        } else {
          group.addTask {
            await self.connect(reference: reference)
          }
        }
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
  }

  func endpoint(for reference: ToolServerReference) async throws -> Endpoint {
    let connection = try connection(for: reference)
    return await Endpoint(id: connection.id, reference: reference, adb: adbService.exec())
  }

  func stop() async {
    guard !isStopped else { return }
    isStopped = true
    for observer in observers.values {
      observer.finish()
    }
    observers.removeAll()
    for task in metadataTasks.values {
      task.cancel()
    }
    metadataTasks.removeAll()
    for task in legacyTasks.values {
      task.cancel()
    }
    legacyTasks.removeAll()
    metadataReadAt.removeAll()
    for connection in connections.values {
      connection.healthTask?.cancel()
    }
    connections.removeAll()
    knownApps.removeAll()
    discoveredKeys.removeAll()
    retryAfter.removeAll()
  }

  private func connect(reference: ToolServerReference) async {
    let key = reference.key
    guard !Task.isCancelled, !isStopped, connections[key] == nil, retryAfter[key] == nil else {
      return
    }

    guard knownApps[key] != nil else { return }
    connections[key] = Connection(id: UUID(), reference: reference)
    checkHealth(for: key)
  }

  private func populateMetadata(sockets: [DiscoveredPluginSocket], using adb: ADBClient) {
    for (deviceID, sockets) in Dictionary(grouping: sockets, by: { $0.reference.deviceId }) {
      guard metadataTasks[deviceID] == nil else { continue }
      let pendingPIDs = Set(sockets.filter {
        guard let app = knownApps[$0.reference.key] else { return true }
        return app.needsMetadataRead(lastAttempt: metadataReadAt[$0.reference.key], now: .now)
      }.map(\.pid))
      let pending = sockets.filter { pendingPIDs.contains($0.pid) }
      guard !pending.isEmpty else { continue }
      metadataTasks[deviceID] = Task { [weak self] in
        await self?.loadMetadata(deviceID: deviceID, sockets: pending, using: adb)
      }
    }
  }

  private func loadMetadata(deviceID: String, sockets: [DiscoveredPluginSocket], using adb: ADBClient) async {
    defer { metadataTasks[deviceID] = nil }
    var batches: [[DiscoveredPluginSocket]] = []
    // Keep a process's visible tools together so every socket receives the same package metadata.
    for process in Dictionary(grouping: sockets, by: \.pid).values {
      if let last = batches.indices.last, batches[last].count + process.count <= 64 {
        batches[last].append(contentsOf: process)
      } else {
        batches.append(process)
      }
    }
    for batch in batches {
      let records = try? await adb.pluginMetadata(
        deviceID: deviceID, socketNames: batch.map(\.reference.socketName), helperURL: helperURL
      )
      guard !Task.isCancelled, !isStopped else { return }
      var changed = false
      for socket in batch {
        let key = socket.reference.key
        guard var app = knownApps[key], app.socketInode == socket.inode,
              discoveredKeys.contains(key) else { continue }
        metadataReadAt[key] = .now
        let hadResult = app.metadata.process.verifiedIdentity != nil || app.metadata.compatibility != .unknown || app.metadataReadFailed
        let record = records?.first { $0.pid == socket.pid }
        let updated = record.map { app.metadata.applyPackageMetadata($0, kind: app.kind) } ?? false
        app.metadataReadFailed = !updated
        if updated { app.awaitingMetadata = false }
        let needsLegacy = app.metadata.needsLegacyProbe
        app.checkingLegacy = needsLegacy && !hadResult
        knownApps[key] = app
        if needsLegacy, legacyTasks[key] == nil {
          legacyTasks[key] = Task { [weak self] in
            await self?.loadLegacyMetadata(socket: socket, using: adb)
          }
        }
        changed = true
      }
      if changed { notifyChange() }
    }
  }

  private func loadLegacyMetadata(socket: DiscoveredPluginSocket, using adb: ADBClient) async {
    let key = socket.reference.key
    let metadata = try? await adb.legacyPluginMetadata(reference: socket.reference, kind: socket.kind, pid: socket.pid)
    guard !Task.isCancelled, !isStopped, discoveredKeys.contains(key),
          var app = knownApps[key], app.socketInode == socket.inode else { return }
    legacyTasks[key] = nil
    app.checkingLegacy = false
    if let metadata { app.metadata.applyLegacyMetadata(metadata, kind: app.kind) }
    knownApps[key] = app
    notifyChange()
  }

  private func checkHealth(for key: String) {
    guard knownApps[key]?.metadata.isLegacy != true else { return }
    guard let connection = connections[key], connection.healthTask == nil else { return }
    connections[key]?.healthTask = Task { [weak self] in
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
      let adb = await adbService.exec()
      let input = try ToolHTTPRequestInput(request: request)
      let operation = ToolHTTPRequestOperation(input: input, requestTimeout: .seconds(2)) {
        try await adb.openLocalAbstract(deviceID: connection.reference.deviceId, abstractSocket: connection.reference.socketName)
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
        retryAfter[key] = .now.advanced(by: Self.retryCooldown)
        connections.removeValue(forKey: key)
        notifyChange()
      }
    }
  }

  private func connection(for reference: ToolServerReference) throws -> Connection {
    guard let connection = connections[reference.key], connection.isReady,
          let app = knownApps[reference.key], !app.awaitingMetadata, let descriptor = app.descriptor,
          descriptor.frontend == nil || descriptor.frontend?.hostApiVersion == 3 else {
      throw ToolError.serverNotConnected(reference)
    }
    return connection
  }
}
