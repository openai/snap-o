import Foundation
import SnapODeviceClient

actor TweaksInspectorService {
  struct App {
    let deviceID: String
    let deviceDisplayTitle: String
    let socketName: String
    let name: String
    let packageName: String
    let appIconBase64: String?
  }

  private struct AppInfo: Decodable {
    let name: String
    let packageName: String
  }

  private struct Connection {
    let app: App
    let forward: ADBForwardHandle
    let baseURL: URL
  }

  private static let socketPrefix = "snapo_tweaks_"

  private let adbService: ADBService
  private let deviceTracker: DeviceTracker
  private var connections: [String: Connection] = [:]

  init(adbService: ADBService, deviceTracker: DeviceTracker) {
    self.adbService = adbService
    self.deviceTracker = deviceTracker
  }

  func listApps() async -> [App] {
    let devices = await deviceTracker.latestDevices
    let adb = await adbService.exec()
    var activeKeys = Set<String>()

    for device in devices {
      guard let output = try? await adb.listUnixSockets(deviceID: device.id) else {
        continue
      }

      for socketName in Self.socketNames(in: output) {
        let key = Self.connectionKey(deviceID: device.id, socketName: socketName)
        activeKeys.insert(key)

        if connections[key] == nil {
          await connect(
            deviceID: device.id,
            deviceDisplayTitle: device.displayTitle,
            socketName: socketName,
            using: adb
          )
        }
      }
    }

    let removedKeys = connections.keys.filter { !activeKeys.contains($0) }
    for key in removedKeys {
      guard let connection = connections.removeValue(forKey: key) else {
        continue
      }
      await adb.removeForward(connection.forward)
    }

    return connections.values.map(\.app).sorted {
      if $0.deviceID != $1.deviceID {
        return $0.deviceID < $1.deviceID
      }
      return $0.packageName < $1.packageName
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
    try Self.validate(response)
    return try JSONDecoder().decode(TweakUpdates.self, from: data)
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
    var forward: ADBForwardHandle?

    do {
      let handle = try await adb.forwardLocalAbstract(
        deviceID: deviceID,
        abstractSocket: socketName
      )
      forward = handle

      guard let baseURL = URL(string: "http://127.0.0.1:\(handle.port)/") else {
        throw NetworkInspectorError.invalidBridgeMessage
      }

      let info = try await load(AppInfo.self, path: "app", baseURL: baseURL)
      let iconData = await loadIcon(baseURL: baseURL)
      let app = App(
        deviceID: deviceID,
        deviceDisplayTitle: deviceDisplayTitle,
        socketName: socketName,
        name: info.name,
        packageName: info.packageName,
        appIconBase64: iconData?.base64EncodedString()
      )
      let key = Self.connectionKey(deviceID: deviceID, socketName: socketName)
      connections[key] = Connection(app: app, forward: handle, baseURL: baseURL)
    } catch {
      if let forward {
        await adb.removeForward(forward)
      }
    }
  }

  private func loadIcon(baseURL: URL) async -> Data? {
    guard let (data, response) = try? await URLSession.shared.data(
      from: baseURL.appending(path: "app/icon")
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
    baseURL: URL
  ) async throws -> T {
    let (data, response) = try await URLSession.shared.data(
      from: baseURL.appending(path: path)
    )
    try Self.validate(response)
    return try JSONDecoder().decode(type, from: data)
  }

  private static func validate(_ response: URLResponse) throws {
    guard let response = response as? HTTPURLResponse,
          (200 ... 299).contains(response.statusCode)
    else {
      throw NetworkInspectorError.invalidBridgeMessage
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
      guard Int(name.dropFirst(socketPrefix.count)) != nil else {
        return nil
      }
      return name
    })).sorted()
  }

  private static func connectionKey(deviceID: String, socketName: String) -> String {
    "\(deviceID):\(socketName)"
  }
}
