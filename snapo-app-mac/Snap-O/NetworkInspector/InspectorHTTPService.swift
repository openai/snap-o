import Foundation
import SnapODeviceClient

actor InspectorHTTPService {
  struct App {
    let kind: InspectorKind
    let deviceID: String
    var deviceDisplayTitle: String
    let socketName: String
    var name: String?
    var packageName: String?
    var processName: String?
    var androidUserID: Int?
    var protocolVersion: Int?
    var appIconBase64: String?
    var instanceID: String?
  }

  private struct AppInfo: Decodable {
    let name: String
    let packageName: String
    let protocolVersion: Int?
    let processName: String?
    let serverStartWallMs: Int64?
    let serverStartMonoNs: Int64?

    var instanceID: String? {
      guard let serverStartWallMs, let serverStartMonoNs else { return nil }
      return "\(serverStartWallMs):\(serverStartMonoNs)"
    }
  }

  private struct ErrorResponse: Decodable {
    let error: String
  }

  private struct Connection {
    let id: UUID
    var app: App
    let forward: ADBForwardHandle
    let baseURL: URL
    var hasLoadedIcon = false
    var metadataTask: Task<Void, Never>?

    var reference: NetworkServerReference {
      NetworkServerReference(deviceId: app.deviceID, socketName: app.socketName)
    }
  }

  private static let discoveryRequestTimeout: TimeInterval = 2
  private static let retryCooldown: Duration = .seconds(3)

  private let adbService: ADBService
  private var connections: [String: Connection] = [:]
  private var retryAfter: [String: ContinuousClock.Instant] = [:]
  private var isStopped = false

  init(adbService: ADBService) {
    self.adbService = adbService
  }

  func currentApps() -> [App] {
    connections.values.map(\.app).sorted {
      if $0.deviceID != $1.deviceID { return $0.deviceID < $1.deviceID }
      return $0.socketName < $1.socketName
    }
  }

  func refresh(devices: [Device], sockets: [DiscoveredInspectorSocket], using adb: ADBClient) async {
    guard !isStopped else { return }
    let devicesByID = Dictionary(uniqueKeysWithValues: devices.map { ($0.id, $0) })
    let activeKeys = Set(sockets.map(\.reference.key))
    retryAfter = retryAfter.filter { activeKeys.contains($0.key) && $0.value > .now }

    await withTaskGroup(of: Void.self) { group in
      for socket in sockets {
        let reference = socket.reference
        guard let device = devicesByID[reference.deviceId], !Task.isCancelled, !isStopped else { continue }
        let key = reference.key
        guard retryAfter[key] == nil else { continue }
        if var connection = connections[key] {
          connection.app.deviceDisplayTitle = device.displayTitle
          connections[key] = connection
          populateMetadata(for: key)
        } else {
          group.addTask {
            await self.connect(
              kind: socket.kind,
              reference: reference,
              deviceDisplayTitle: device.displayTitle,
              using: adb
            )
          }
        }
      }
    }

    guard !Task.isCancelled, !isStopped else { return }
    for key in connections.keys.filter({ !activeKeys.contains($0) }) {
      guard let connection = connections.removeValue(forKey: key) else { continue }
      connection.metadataTask?.cancel()
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
    for connection in connections.values {
      connection.metadataTask?.cancel()
    }
    let adb = await adbService.exec()
    let forwards = connections.values.map(\.forward)
    connections.removeAll()
    retryAfter.removeAll()

    for forward in forwards {
      await removeForward(forward, using: adb)
    }
  }

  private func connect(
    kind: InspectorKind,
    reference: NetworkServerReference,
    deviceDisplayTitle: String,
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
        throw NetworkInspectorError.invalidBridgeMessage
      }

      async let processName = NetworkServerDiscovery.packageNameHint(for: reference, using: adb)
      async let androidUserID = NetworkServerDiscovery.androidUserID(for: reference, using: adb)
      let metadata = await (processName: processName, androidUserID: androidUserID)
      guard !Task.isCancelled, !isStopped else {
        await removeForward(handle, using: adb)
        return
      }
      let app = App(
        kind: kind,
        deviceID: reference.deviceId,
        deviceDisplayTitle: deviceDisplayTitle,
        socketName: reference.socketName,
        processName: metadata.processName,
        androidUserID: metadata.androidUserID
      )
      connections[key] = Connection(id: UUID(), app: app, forward: handle, baseURL: baseURL)
      populateMetadata(for: key)
    } catch {
      if !Task.isCancelled, !isStopped {
        retryAfter[key] = .now.advanced(by: Self.retryCooldown)
      }
      if let forward {
        await removeForward(forward, using: adb)
      }
    }
  }

  private func populateMetadata(for key: String) {
    guard let connection = connections[key],
          connection.metadataTask == nil else { return }
    connections[key]?.metadataTask = Task { [weak self] in
      await self?.loadMetadata(for: key, connectionID: connection.id)
    }
  }

  private func loadMetadata(for key: String, connectionID: UUID) async {
    defer {
      if connections[key]?.id == connectionID {
        connections[key]?.metadataTask = nil
      }
    }
    guard let connection = connections[key], connection.id == connectionID else { return }

    if connection.app.processName == nil || connection.app.androidUserID == nil {
      let adb = await adbService.exec()
      async let processName = NetworkServerDiscovery.packageNameHint(for: connection.reference, using: adb)
      async let androidUserID = NetworkServerDiscovery.androidUserID(for: connection.reference, using: adb)
      let metadata = await (processName: processName, androidUserID: androidUserID)
      guard !Task.isCancelled, connections[key]?.id == connectionID else { return }
      connections[key]?.app.processName = metadata.processName ?? connection.app.processName
      connections[key]?.app.androidUserID = metadata.androidUserID ?? connection.app.androidUserID
    }

    if let info = try? await load(
      AppInfo.self,
      path: ".snap-o/info",
      connection: connection,
      timeoutInterval: Self.discoveryRequestTimeout
    ),
      !Task.isCancelled,
      var current = connections[key], current.id == connectionID {
      current.app.name = info.name
      current.app.packageName = info.packageName
      current.app.protocolVersion = info.protocolVersion ?? 1
      current.app.processName = info.processName ?? current.app.processName
      current.app.instanceID = info.instanceID
      connections[key] = current
    }

    guard !Task.isCancelled, connections[key]?.id == connectionID, !connection.hasLoadedIcon else { return }
    do {
      let icon = try await loadIcon(connection: connection)
      guard !Task.isCancelled,
            var current = connections[key], current.id == connectionID else { return }
      current.app.appIconBase64 = icon?.base64EncodedString()
      current.hasLoadedIcon = true
      connections[key] = current
    } catch {
      // Retry transient failures on the next discovery refresh.
    }
  }

  private func loadIcon(connection: Connection) async throws -> Data? {
    let request = URLRequest(
      url: connection.baseURL.appending(path: ".snap-o/appicon"),
      timeoutInterval: Self.discoveryRequestTimeout
    )
    let (data, response) = try await data(for: request, connection: connection)
    if (response as? HTTPURLResponse)?.statusCode == 404 { return nil }
    try Self.validate(response, data: data)
    return data
  }

  private func connection(for reference: InspectorServerReference) throws -> Connection {
    guard let connection = connections[reference.key] else {
      throw NetworkInspectorError.serverNotConnected(reference)
    }
    return connection
  }

  private func load<T: Decodable>(
    _ type: T.Type,
    path: String,
    connection: Connection,
    timeoutInterval: TimeInterval? = nil
  ) async throws -> T {
    var request = URLRequest(url: connection.baseURL.appending(path: path))
    if let timeoutInterval {
      request.timeoutInterval = timeoutInterval
    }

    let (data, response) = try await data(for: request, connection: connection)
    try Self.validate(response, data: data)
    return try JSONDecoder().decode(type, from: data)
  }

  private func data(for request: URLRequest, connection: Connection) async throws -> (Data, URLResponse) {
    do {
      let configuration = URLSessionConfiguration.ephemeral
      configuration.connectionProxyDictionary = [:]
      configuration.httpCookieStorage = nil
      configuration.urlCredentialStorage = nil
      let session = URLSession(configuration: configuration, delegate: InspectorHTTPRedirectPolicy(), delegateQueue: nil)
      defer { session.invalidateAndCancel() }
      let (bytes, response) = try await session.bytes(for: request)
      var data = Data()
      for try await byte in bytes {
        guard data.count < 1_048_576 else { throw NetworkInspectorError.invalidBridgeMessage }
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
    let adb = await adbService.exec()
    await removeForward(connection.forward, using: adb)
  }

  private func removeForward(_ forward: ADBForwardHandle, using adb: ADBClient) async {
    // Cleanup must still run when metadata loading or discovery was cancelled.
    await Task { await adb.removeForward(forward) }.value
  }

  private static func validate(_ response: URLResponse, data: Data? = nil) throws {
    guard let response = response as? HTTPURLResponse else {
      throw NetworkInspectorError.invalidBridgeMessage
    }
    guard (200 ... 299).contains(response.statusCode) else {
      let message = data.flatMap { try? JSONDecoder().decode(ErrorResponse.self, from: $0).error }
        ?? "Inspector request failed (\(response.statusCode))."
      throw NetworkInspectorError.tweakRequestFailed(
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
