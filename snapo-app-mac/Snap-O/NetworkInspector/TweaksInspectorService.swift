import Foundation
import SnapODeviceClient

actor TweaksInspectorService {
  struct App {
    let deviceID: String
    var deviceDisplayTitle: String
    let socketName: String
    var name: String?
    var packageName: String?
    var processName: String?
    var protocolVersion: Int?
    var appIconBase64: String?
  }

  private struct AppInfo: Decodable {
    let name: String
    let packageName: String
    let protocolVersion: Int?
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

  private let adbService: ADBService
  private var connections: [String: Connection] = [:]
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

  func refresh(devices: [Device], references: [NetworkServerReference], using adb: ADBClient) async {
    guard !isStopped else { return }
    let devicesByID = Dictionary(uniqueKeysWithValues: devices.map { ($0.id, $0) })
    let activeKeys = Set(references.map(\.key))

    await withTaskGroup(of: Void.self) { group in
      for reference in references {
        guard let device = devicesByID[reference.deviceId], !Task.isCancelled, !isStopped else { continue }
        let key = reference.key
        if var connection = connections[key] {
          connection.app.deviceDisplayTitle = device.displayTitle
          connections[key] = connection
          populateMetadata(for: key)
        } else {
          group.addTask {
            await self.connect(
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
      await adb.removeForward(connection.forward)
    }
  }

  func listTweaks(for reference: InspectorServerReference) async throws -> TweakList {
    let connection = try connection(for: reference)
    return try await load(TweakList.self, path: "tweaks", connection: connection)
  }

  func updateTweaks(_ input: UpdateTweaksInput) async throws -> TweakUpdates {
    let connection = try connection(for: input.server)
    var request = URLRequest(url: connection.baseURL.appending(path: "tweaks"))
    request.httpMethod = "PATCH"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONEncoder().encode(TweakPatch(values: input.values))

    let (data, response) = try await data(for: request, connection: connection)
    try Self.validate(response, data: data)
    return try JSONDecoder().decode(TweakUpdates.self, from: data)
  }

  func invokeTweakAction(_ input: InvokeTweakActionInput) async throws {
    let connection = try connection(for: input.server)
    var request = URLRequest(url: connection.baseURL.appending(path: "tweaks/action"))
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONEncoder().encode(TweakAction(name: input.name))

    let (data, response) = try await data(for: request, connection: connection)
    try Self.validate(response, data: data)
  }

  func streamTweaks(
    for reference: InspectorServerReference,
    onChange: @escaping @Sendable (TweakList) async -> Void
  ) async throws {
    let connection = try connection(for: reference)
    var request = URLRequest(url: connection.baseURL.appending(path: "tweaks/events"))
    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")

    do {
      let (bytes, response) = try await URLSession.shared.bytes(for: request)
      try Self.validate(response)

      // SSE frames end with an empty line, which AsyncBytes.lines omits.
      var decoder = TweakEventStreamDecoder()

      for try await byte in bytes {
        try Task.checkCancellation()

        guard let data = decoder.consume(byte) else { continue }
        let tweaks = try JSONDecoder().decode(TweakList.self, from: data)
        await onChange(tweaks)
      }
    } catch {
      await invalidateConnection(connection, after: error)
      throw error
    }
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

    for forward in forwards {
      await adb.removeForward(forward)
    }
  }

  private func connect(
    reference: NetworkServerReference,
    deviceDisplayTitle: String,
    using adb: ADBClient
  ) async {
    let key = reference.key
    guard !Task.isCancelled, !isStopped, connections[key] == nil else {
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
        await adb.removeForward(handle)
        return
      }

      guard let baseURL = URL(string: "http://127.0.0.1:\(handle.port)/") else {
        throw NetworkInspectorError.invalidBridgeMessage
      }

      let processName = await NetworkServerDiscovery.packageNameHint(for: reference, using: adb)
      guard !Task.isCancelled, !isStopped else {
        await adb.removeForward(handle)
        return
      }
      let app = App(
        deviceID: reference.deviceId,
        deviceDisplayTitle: deviceDisplayTitle,
        socketName: reference.socketName,
        processName: processName
      )
      connections[key] = Connection(id: UUID(), app: app, forward: handle, baseURL: baseURL)
      populateMetadata(for: key)
    } catch {
      if let forward {
        await adb.removeForward(forward)
      }
    }
  }

  private func populateMetadata(for key: String) {
    guard let connection = connections[key],
          connection.app.protocolVersion == nil || connection.app.processName == nil || !connection.hasLoadedIcon,
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

    if connection.app.processName == nil {
      let adb = await adbService.exec()
      let processName = await NetworkServerDiscovery.packageNameHint(for: connection.reference, using: adb)
      guard !Task.isCancelled, connections[key]?.id == connectionID else { return }
      connections[key]?.app.processName = processName
    }

    if connection.app.protocolVersion == nil,
       let info = try? await load(
         AppInfo.self,
         path: "app",
         connection: connection,
         timeoutInterval: Self.discoveryRequestTimeout
       ),
       !Task.isCancelled,
       var current = connections[key], current.id == connectionID {
      current.app.name = info.name
      current.app.packageName = info.packageName
      current.app.protocolVersion = info.protocolVersion ?? 1
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
      url: connection.baseURL.appending(path: "app/icon"),
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
      return try await URLSession.shared.data(for: request)
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

    // A brief device disconnect can remove the forward without changing the Android socket.
    connections.removeValue(forKey: key)?.metadataTask?.cancel()
    let adb = await adbService.exec()
    await adb.removeForward(connection.forward)
  }

  private static func validate(_ response: URLResponse, data: Data? = nil) throws {
    guard let response = response as? HTTPURLResponse else {
      throw NetworkInspectorError.invalidBridgeMessage
    }
    guard (200 ... 299).contains(response.statusCode) else {
      let message = data.flatMap { try? JSONDecoder().decode(ErrorResponse.self, from: $0).error }
        ?? "Tweak request failed (\(response.statusCode))."
      throw NetworkInspectorError.tweakRequestFailed(
        statusCode: response.statusCode,
        message: message
      )
    }
  }
}
