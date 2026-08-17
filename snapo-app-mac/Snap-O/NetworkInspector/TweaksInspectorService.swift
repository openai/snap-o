import Foundation
import SnapODeviceClient

actor TweaksInspectorService {
  struct App {
    let deviceID: String
    var deviceDisplayTitle: String
    let socketName: String
    var name: String?
    var packageName: String?
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
    var metadataTask: Task<Void, Never>?
  }

  private static let socketPrefix = "snapo_tweaks_"
  private static let discoveryRequestTimeout: TimeInterval = 2

  private let adbService: ADBService
  private let deviceTracker: DeviceTracker
  private var connections: [String: Connection] = [:]
  private var refreshTask: Task<Void, Never>?
  private var isStopped = false

  init(adbService: ADBService, deviceTracker: DeviceTracker) {
    self.adbService = adbService
    self.deviceTracker = deviceTracker
  }

  func listApps() async -> [App] {
    guard !isStopped else { return [] }
    if let refreshTask {
      await refreshTask.value
    } else {
      let task = Task<Void, Never> { [weak self] in
        await self?.refreshNow()
      }
      refreshTask = task
      await task.value
      refreshTask = nil
    }

    return connections.values.map(\.app).sorted {
      if $0.deviceID != $1.deviceID {
        return $0.deviceID < $1.deviceID
      }
      return $0.socketName < $1.socketName
    }
  }

  private func refreshNow() async {
    let devices = await deviceTracker.latestDevices
    let adb = await adbService.exec()
    var activeKeys = Set<String>()

    await withTaskGroup(of: Void.self) { group in
      for device in devices {
        guard !Task.isCancelled, !isStopped,
              let output = try? await adb.listUnixSockets(deviceID: device.id) else {
          continue
        }

        for socketName in Self.socketNames(in: output) {
          let key = Self.connectionKey(deviceID: device.id, socketName: socketName)
          activeKeys.insert(key)

          if var connection = connections[key] {
            connection.app.deviceDisplayTitle = device.displayTitle
            connections[key] = connection
            populateMetadata(for: key)
          } else {
            group.addTask {
              await self.connect(
                deviceID: device.id,
                deviceDisplayTitle: device.displayTitle,
                socketName: socketName,
                using: adb
              )
            }
          }
        }
      }
    }

    guard !Task.isCancelled, !isStopped else { return }
    let removedKeys = connections.keys.filter { !activeKeys.contains($0) }
    for key in removedKeys {
      guard let connection = connections.removeValue(forKey: key) else {
        continue
      }
      connection.metadataTask?.cancel()
      await adb.removeForward(connection.forward)
    }
  }

  func listTweaks(for reference: InspectorServerReference) async throws -> TweakList {
    let connection = try connection(for: reference)
    return try await load(TweakList.self, path: "tweaks", baseURL: connection.baseURL)
  }

  func updateTweaks(_ input: UpdateTweaksInput) async throws -> TweakUpdates {
    let connection = try connection(for: input.server)
    var request = URLRequest(url: connection.baseURL.appending(path: "tweaks"))
    request.httpMethod = "PATCH"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONEncoder().encode(TweakPatch(values: input.values))

    let (data, response) = try await URLSession.shared.data(for: request)
    try Self.validate(response, data: data)
    return try JSONDecoder().decode(TweakUpdates.self, from: data)
  }

  func invokeTweakAction(_ input: InvokeTweakActionInput) async throws {
    let connection = try connection(for: input.server)
    var request = URLRequest(url: connection.baseURL.appending(path: "tweaks/action"))
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONEncoder().encode(TweakAction(name: input.name))

    let (data, response) = try await URLSession.shared.data(for: request)
    try Self.validate(response, data: data)
  }

  func streamTweaks(
    for reference: InspectorServerReference,
    onChange: @escaping @Sendable (TweakList) async -> Void
  ) async throws {
    let connection = try connection(for: reference)
    var request = URLRequest(url: connection.baseURL.appending(path: "tweaks/events"))
    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")

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
  }

  func stop() async {
    guard !isStopped else { return }
    isStopped = true
    refreshTask?.cancel()
    refreshTask = nil
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
    deviceID: String,
    deviceDisplayTitle: String,
    socketName: String,
    using adb: ADBClient
  ) async {
    let key = Self.connectionKey(deviceID: deviceID, socketName: socketName)
    guard !Task.isCancelled, !isStopped, connections[key] == nil else {
      return
    }

    var forward: ADBForwardHandle?

    do {
      let handle = try await adb.forwardLocalAbstract(
        deviceID: deviceID,
        abstractSocket: socketName
      )
      forward = handle

      guard !Task.isCancelled, !isStopped else {
        await adb.removeForward(handle)
        return
      }

      guard let baseURL = URL(string: "http://127.0.0.1:\(handle.port)/") else {
        throw NetworkInspectorError.invalidBridgeMessage
      }

      let app = App(
        deviceID: deviceID,
        deviceDisplayTitle: deviceDisplayTitle,
        socketName: socketName
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
          connection.app.protocolVersion == nil || connection.app.appIconBase64 == nil,
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

    if connection.app.protocolVersion == nil,
       let info = try? await load(
         AppInfo.self,
         path: "app",
         baseURL: connection.baseURL,
         timeoutInterval: Self.discoveryRequestTimeout
       ),
       !Task.isCancelled,
       var current = connections[key], current.id == connectionID {
      current.app.name = info.name
      current.app.packageName = info.packageName
      current.app.protocolVersion = info.protocolVersion ?? 1
      connections[key] = current
    }

    guard !Task.isCancelled, connection.app.appIconBase64 == nil,
          let icon = await loadIcon(baseURL: connection.baseURL),
          !Task.isCancelled,
          var current = connections[key], current.id == connectionID else { return }
    current.app.appIconBase64 = icon.base64EncodedString()
    connections[key] = current
  }

  private func loadIcon(baseURL: URL) async -> Data? {
    let request = URLRequest(
      url: baseURL.appending(path: "app/icon"),
      timeoutInterval: Self.discoveryRequestTimeout
    )
    guard let (data, response) = try? await URLSession.shared.data(
      for: request
    ),
      let httpResponse = response as? HTTPURLResponse,
      (200 ... 299).contains(httpResponse.statusCode)
    else {
      return nil
    }
    return data
  }

  private func connection(for reference: InspectorServerReference) throws -> Connection {
    let key = Self.connectionKey(deviceID: reference.deviceId, socketName: reference.socketName)
    guard let connection = connections[key] else {
      throw NetworkInspectorError.invalidBridgeMessage
    }
    return connection
  }

  private func load<T: Decodable>(
    _ type: T.Type,
    path: String,
    baseURL: URL,
    timeoutInterval: TimeInterval? = nil
  ) async throws -> T {
    var request = URLRequest(url: baseURL.appending(path: path))
    if let timeoutInterval {
      request.timeoutInterval = timeoutInterval
    }

    let (data, response) = try await URLSession.shared.data(for: request)
    try Self.validate(response, data: data)
    return try JSONDecoder().decode(type, from: data)
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

  private static func socketNames(in output: String) -> [String] {
    Array(Set(output.split(separator: "\n").compactMap { line in
      guard let token = line.split(whereSeparator: \.isWhitespace).last else {
        return nil
      }
      let socket = String(token)
      guard socket.hasPrefix("@\(socketPrefix)") else {
        return nil
      }
      let name = String(socket.dropFirst())
      guard InspectorKind.tweaks.pid(inSocketName: name) != nil else {
        return nil
      }
      return name
    })).sorted()
  }

  private static func connectionKey(deviceID: String, socketName: String) -> String {
    "\(deviceID):\(socketName)"
  }
}
