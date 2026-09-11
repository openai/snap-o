import Foundation
import SnapODeviceClient

actor InspectorHTTPService {
  struct App {
    let kind: InspectorID
    let pid: Int
    let deviceID: String
    var deviceDisplayTitle: String
    let socketName: String
    var processNameHint: String?
    var manifest: InspectorProcessMetadata?
    var socketInode: String?
    var awaitingManifest = false
    var isConnected = false

    var name: String? {
      manifest?.app?.name
    }

    var packageName: String? {
      manifest?.app?.packageName
    }

    var processName: String? {
      manifest?.processName ?? processNameHint
    }

    var androidUserID: Int? {
      manifest?.androidUserId
    }

    var appIconBase64: String? {
      manifest?.app?.iconBase64
    }

    var descriptor: InspectorDescriptor? {
      manifest?.app?.inspectors.first { $0.id == kind }
    }

    var protocolVersion: Int? {
      manifest?.app == nil ? nil : descriptor?.protocolVersion ?? 0
    }
  }

  private struct ErrorResponse: Decodable {
    let error: String
  }

  private struct Connection {
    let id: UUID
    let reference: InspectorServerReference
    let forward: ADBForwardHandle
    let baseURL: URL
    var isReady = false
    var healthTask: Task<Void, Never>?
  }

  private static let discoveryRequestTimeout: TimeInterval = 2
  private static let retryCooldown: Duration = .seconds(3)

  private let adbService: ADBService
  private var connections: [String: Connection] = [:]
  private var knownApps: [String: App] = [:]
  private var discoveredKeys: Set<String> = []
  private var retryAfter: [String: ContinuousClock.Instant] = [:]
  private var metadataTasks: [String: Task<Void, Never>] = [:]
  private var metadataReadAt: [String: ContinuousClock.Instant] = [:]
  private let helperURL: URL
  private let session: URLSession
  private var observers: [UUID: AsyncStream<Void>.Continuation] = [:]
  private var snapshotRevision: UInt64 = 0
  private var isStopped = false

  init(adbService: ADBService, helperURL: URL? = nil) {
    self.adbService = adbService
    self.helperURL = helperURL ?? (Bundle.main.resourceURL ?? Bundle.main.bundleURL.appending(path: "Contents/Resources"))
      .appending(path: "snapo-discovery.jar")
    let configuration = URLSessionConfiguration.ephemeral
    configuration.connectionProxyDictionary = [:]
    configuration.httpCookieStorage = nil
    configuration.urlCredentialStorage = nil
    session = URLSession(configuration: configuration, delegate: InspectorHTTPRedirectPolicy(), delegateQueue: nil)
  }

  func currentApps() -> (revision: UInt64, apps: [App]) {
    snapshotRevision += 1
    let apps = discoveredKeys.compactMap { key -> App? in
      guard var app = knownApps[key] else { return nil }
      app.isConnected = connections[key]?.isReady == true && !app.awaitingManifest
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

  func refresh(devices: [Device], sockets: [DiscoveredInspectorSocket], using adb: ADBClient) async {
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
        if let connection = connections.removeValue(forKey: reference.key) {
          connection.healthTask?.cancel()
          await removeForward(connection.forward, using: adb)
        }
        if let processName = socket.processName, processName == previous.processName {
          // Keep display metadata, but verify the process before using a replacement listener.
          previous.socketInode = socket.inode
          previous.awaitingManifest = true
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
        knownApps[reference.key]?.processNameHint = processName
      }
    }
    populateManifests(sockets: sockets.filter { activeKeys.contains($0.reference.key) }, using: adb)
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
            await self.connect(
              reference: reference,
              using: adb
            )
          }
        }
      }
    }

    guard !Task.isCancelled, !isStopped else { return }
    for key in connections.keys.filter({ !activeKeys.contains($0) }) {
      guard let connection = connections.removeValue(forKey: key) else { continue }
      connection.healthTask?.cancel()
      await removeForward(connection.forward, using: adb)
    }
  }

  struct Endpoint {
    let id: UUID
    let baseURL: URL
  }

  func endpoint(for reference: InspectorServerReference) throws -> Endpoint {
    let connection = try connection(for: reference)
    return Endpoint(id: connection.id, baseURL: connection.baseURL)
  }

  private func isCurrent(_ connection: Connection) -> Bool {
    !isStopped && connections[connection.reference.key]?.id == connection.id
  }

  func stop() async {
    guard !isStopped else { return }
    isStopped = true
    session.invalidateAndCancel()
    for observer in observers.values {
      observer.finish()
    }
    observers.removeAll()
    for task in metadataTasks.values {
      task.cancel()
    }
    metadataTasks.removeAll()
    metadataReadAt.removeAll()
    for connection in connections.values {
      connection.healthTask?.cancel()
    }
    let adb = await adbService.exec()
    let forwards = connections.values.map(\.forward)
    connections.removeAll()
    knownApps.removeAll()
    discoveredKeys.removeAll()
    retryAfter.removeAll()

    for forward in forwards {
      await removeForward(forward, using: adb)
    }
  }

  private func connect(
    reference: InspectorServerReference,
    using adb: ADBClient
  ) async {
    let key = reference.key
    guard !Task.isCancelled, !isStopped, connections[key] == nil, retryAfter[key] == nil else {
      return
    }

    var forward: ADBForwardHandle?

    do {
      let handle = try await adb.forwardLocalAbstract(
        deviceID: reference.deviceId,
        abstractSocket: reference.socketName
      )
      forward = handle

      guard !Task.isCancelled, !isStopped else {
        await removeForward(handle, using: adb)
        return
      }

      guard let baseURL = URL(string: "http://127.0.0.1:\(handle.port)/") else {
        throw InspectorError.invalidBridgeMessage
      }

      guard knownApps[key] != nil else {
        await removeForward(handle, using: adb)
        return
      }
      connections[key] = Connection(id: UUID(), reference: reference, forward: handle, baseURL: baseURL)
      checkHealth(for: key)
    } catch {
      if !Task.isCancelled, !isStopped {
        retryAfter[key] = .now.advanced(by: Self.retryCooldown)
      }
      if let forward {
        await removeForward(forward, using: adb)
      }
    }
  }

  private func populateManifests(sockets: [DiscoveredInspectorSocket], using adb: ADBClient) {
    for (deviceID, sockets) in Dictionary(grouping: sockets, by: { $0.reference.deviceId }) {
      guard metadataTasks[deviceID] == nil else { continue }
      let pendingPIDs = Set(sockets.filter {
        guard let readAt = metadataReadAt[$0.reference.key] else { return true }
        return readAt.duration(to: .now) >= .seconds(30)
      }.map(\.pid))
      let pending = sockets.filter { pendingPIDs.contains($0.pid) }
      guard !pending.isEmpty else { continue }
      metadataTasks[deviceID] = Task { [weak self] in
        await self?.loadManifests(deviceID: deviceID, sockets: pending, using: adb)
      }
    }
  }

  private func loadManifests(deviceID: String, sockets: [DiscoveredInspectorSocket], using adb: ADBClient) async {
    defer { metadataTasks[deviceID] = nil }
    var batches: [[DiscoveredInspectorSocket]] = []
    // Keep a process's visible inspectors together so every socket receives the same manifest.
    for process in Dictionary(grouping: sockets, by: \.pid).values {
      if let last = batches.indices.last, batches[last].count + process.count <= 64 {
        batches[last].append(contentsOf: process)
      } else {
        batches.append(process)
      }
    }
    for batch in batches {
      let records = try? await adb.inspectorMetadata(
        deviceID: deviceID, socketNames: batch.map(\.reference.socketName), helperURL: helperURL
      )
      guard !Task.isCancelled, !isStopped else { return }
      var changed = false
      for socket in batch {
        let key = socket.reference.key
        guard var app = knownApps[key], app.socketInode == socket.inode,
              discoveredKeys.contains(key) else { continue }
        // Failed or unsupported metadata is retried without probing the app's HTTP server.
        metadataReadAt[key] = .now
        guard let record = records?.first(where: { $0.pid == socket.pid }), record.app != nil else { continue }
        guard app.manifest != record || app.awaitingManifest else { continue }
        app.manifest = record
        app.awaitingManifest = false
        knownApps[key] = app
        changed = true
      }
      if changed { notifyChange() }
    }
  }

  private func checkHealth(for key: String) {
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
    var request = URLRequest(url: connection.baseURL, timeoutInterval: Self.discoveryRequestTimeout)
    request.httpMethod = "OPTIONS"
    do {
      let (data, response) = try await data(for: request, connection: connection)
      try Self.validate(response, data: data)
      guard !Task.isCancelled, connections[key]?.id == connectionID else { return }
      let changed = connections[key]?.isReady != true
      connections[key]?.isReady = true
      if changed { notifyChange() }
    } catch {
      if connections[key]?.id == connectionID {
        let changed = connections[key]?.isReady == true
        connections[key]?.isReady = false
        if changed { notifyChange() }
      }
    }
  }

  private func connection(for reference: InspectorServerReference) throws -> Connection {
    guard let connection = connections[reference.key], connection.isReady,
          knownApps[reference.key]?.awaitingManifest == false else {
      throw InspectorError.serverNotConnected(reference)
    }
    return connection
  }

  private func data(for request: URLRequest, connection: Connection) async throws -> (Data, URLResponse) {
    do {
      let (bytes, response) = try await session.bytes(for: request)
      var data = Data()
      for try await byte in bytes {
        guard data.count < 1_048_576 else { throw InspectorError.invalidBridgeMessage }
        data.append(byte)
      }
      guard isCurrent(connection) else { throw CancellationError() }
      return (data, response)
    } catch {
      await invalidateConnection(connection, after: error)
      throw error
    }
  }

  private func invalidateConnection(_ connection: Connection, after error: Error) async {
    guard let error = error as? URLError,
          [.cannotConnectToHost, .networkConnectionLost, .notConnectedToInternet, .timedOut].contains(error.code)
    else { return }
    let key = connection.reference.key
    guard connections[key]?.id == connection.id else { return }

    // Frozen apps keep listening but cannot accept connections. Avoid filling their queues on every scan.
    retryAfter[key] = .now.advanced(by: Self.retryCooldown)
    // A brief device disconnect can remove the forward without changing the Android socket.
    connections.removeValue(forKey: key)
    notifyChange()
    let adb = await adbService.exec()
    await removeForward(connection.forward, using: adb)
  }

  private func removeForward(_ forward: ADBForwardHandle, using adb: ADBClient) async {
    // Cleanup must still run when metadata loading or discovery was cancelled.
    await Task { await adb.removeForward(forward) }.value
  }

  private static func validate(_ response: URLResponse, data: Data? = nil) throws {
    guard let response = response as? HTTPURLResponse else {
      throw InspectorError.invalidBridgeMessage
    }
    guard (200 ... 299).contains(response.statusCode) else {
      let message = data.flatMap { try? JSONDecoder().decode(ErrorResponse.self, from: $0).error }
        ?? "Inspector request failed (\(response.statusCode))."
      throw InspectorError.requestFailed(
        statusCode: response.statusCode,
        message: message
      )
    }
  }
}

private final class InspectorHTTPRedirectPolicy: NSObject, URLSessionTaskDelegate {
  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest,
    completionHandler: @escaping @Sendable (URLRequest?) -> Void
  ) {
    completionHandler(nil)
  }
}
