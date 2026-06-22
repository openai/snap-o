import Foundation

actor NetworkInspectorService {
  private struct ServerState {
    let reference: NetworkServerReference
    let connection: NetworkInspectorConnection
    var deviceDisplayTitle: String
    var appInfo: NetworkAppInfo?
    var packageNameHint: String?
  }

  private struct PendingCommandKey: Hashable {
    let serverKey: String
    let id: Int
  }

  private struct RefreshFlight {
    let id: UUID
    let task: Task<Void, Never>
  }

  private static let supportedProtocolVersion = 1

  private let deviceTracker: DeviceTracker
  private var servers: [String: ServerState] = [:]
  private var streams: [String: String] = [:]
  private var pendingCommands: [
    PendingCommandKey: CheckedContinuation<NetworkCDPMessage, Error>
  ] = [:]
  private var outputContinuations: [UUID: AsyncStream<NetworkInspectorOutput>.Continuation] = [:]
  private var refreshFlight: RefreshFlight?
  private var nextCommandID = 1

  init(deviceTracker: DeviceTracker) {
    self.deviceTracker = deviceTracker
  }

  func outputStream() -> AsyncStream<NetworkInspectorOutput> {
    let id = UUID()
    let (stream, continuation) = AsyncStream<NetworkInspectorOutput>.makeStream()
    outputContinuations[id] = continuation
    continuation.onTermination = { [weak self] _ in
      Task { await self?.removeOutputContinuation(id) }
    }
    return stream
  }

  func listServers() async -> [NetworkInspectorServer] {
    await refresh()
    return currentServers()
  }

  func startStream(_ reference: NetworkServerReference) async throws -> NetworkStreamStarted {
    await refresh()
    guard let state = servers[reference.key] else {
      throw NetworkInspectorError.serverNotConnected(reference)
    }

    if !streams.values.contains(reference.key) {
      try state.connection.startStream()
    }

    let streamID = UUID().uuidString
    streams[streamID] = reference.key
    emit(
      .status(
        NetworkStreamStatus(
          streamId: streamID,
          state: "started",
          message: "Connected to \(reference.deviceId)/\(reference.socketName)",
          code: nil,
          signal: nil
        )
      )
    )
    return NetworkStreamStarted(streamId: streamID)
  }

  func stopStream(_ streamID: String) {
    guard let key = streams.removeValue(forKey: streamID) else { return }
    guard !streams.values.contains(key) else { return }
    try? servers[key]?.connection.stopStream()
  }

  func stopAllStreams() {
    let serverKeys = Set(streams.values)
    streams.removeAll()
    for serverKey in serverKeys {
      try? servers[serverKey]?.connection.stopStream()
    }
  }

  func loadBodies(_ input: NetworkLoadBodiesInput) async -> NetworkRequestBodies {
    let reference = NetworkServerReference(deviceId: input.deviceId, socketName: input.socketName)

    async let requestMessage: NetworkCDPMessage? = optionalCommand(
      enabled: input.includeRequestBody ?? true,
      serverKey: reference.key,
      method: "Network.getRequestPostData",
      requestID: input.requestId
    )
    async let responseMessage: NetworkCDPMessage? = optionalCommand(
      enabled: input.includeResponseBody ?? true,
      serverKey: reference.key,
      method: "Network.getResponseBody",
      requestID: input.requestId
    )

    let (request, response) = await (requestMessage, responseMessage)
    return NetworkRequestBodies(
      requestId: input.requestId,
      requestBody: request?.result?["postData"]?.stringValue,
      responseBody: response?.result?["body"]?.stringValue,
      responseBodyBase64Encoded: response?.result?["base64Encoded"]?.boolValue
    )
  }

  func stop() {
    refreshFlight?.task.cancel()
    refreshFlight = nil
    let connections = servers.values.map(\.connection)
    servers.removeAll()
    streams.removeAll()
    for connection in connections {
      connection.close()
    }
    for continuation in pendingCommands.values {
      continuation.resume(throwing: NetworkInspectorError.serverDisconnected)
    }
    pendingCommands.removeAll()
  }

  private func optionalCommand(
    enabled: Bool,
    serverKey: String,
    method: String,
    requestID: String
  ) async -> NetworkCDPMessage? {
    guard enabled else { return nil }
    return try? await sendCommand(
      serverKey: serverKey,
      method: method,
      params: ["requestId": .string(requestID)]
    )
  }

  private func sendCommand(
    serverKey: String,
    method: String,
    params: [String: JSONValue]
  ) async throws -> NetworkCDPMessage {
    guard let connection = servers[serverKey]?.connection else {
      let parts = serverKey.split(separator: "\0", omittingEmptySubsequences: false)
      let reference = NetworkServerReference(
        deviceId: parts.first.map(String.init) ?? "unknown",
        socketName: parts.dropFirst().first.map(String.init) ?? "unknown"
      )
      throw NetworkInspectorError.serverNotConnected(reference)
    }

    let id = nextCommandID
    nextCommandID += 1
    let pendingKey = PendingCommandKey(serverKey: serverKey, id: id)

    return try await withCheckedThrowingContinuation { continuation in
      pendingCommands[pendingKey] = continuation
      do {
        try connection.send(NetworkCDPMessage(id: id, method: method, params: params))
      } catch {
        pendingCommands.removeValue(forKey: pendingKey)
        continuation.resume(throwing: error)
        return
      }

      Task { [weak self] in
        try? await Task.sleep(for: .milliseconds(1500))
        await self?.timeoutCommand(pendingKey, method: method)
      }
    }
  }

  private func timeoutCommand(_ key: PendingCommandKey, method: String) {
    guard let continuation = pendingCommands.removeValue(forKey: key) else { return }
    continuation.resume(throwing: NetworkInspectorError.timedOut(method))
  }

  private func refresh() async {
    if let refreshFlight {
      await refreshFlight.task.value
      return
    }

    let id = UUID()
    let task = Task<Void, Never> { [weak self] in
      guard let self else { return }
      await refreshNow()
    }
    refreshFlight = RefreshFlight(id: id, task: task)
    await task.value
    if refreshFlight?.id == id {
      refreshFlight = nil
    }
  }

  private func refreshNow() async {
    let devices = deviceTracker.latestDevices
    var seenKeys = Set<String>()

    for device in devices {
      let socketNames = await (try? networkSocketNames(deviceID: device.id)) ?? []
      guard !Task.isCancelled else { return }
      for socketName in socketNames {
        let reference = NetworkServerReference(deviceId: device.id, socketName: socketName)
        seenKeys.insert(reference.key)

        if var state = servers[reference.key] {
          state.deviceDisplayTitle = device.displayTitle
          servers[reference.key] = state
          continue
        }

        await connect(device: device, reference: reference)
        guard !Task.isCancelled else { return }
      }
    }

    let removedKeys = servers.keys.filter { !seenKeys.contains($0) }
    for key in removedKeys {
      removeServer(key, message: nil)
    }
  }

  private func connect(device: Device, reference: NetworkServerReference) async {
    do {
      let socket = try await Task.detached(priority: .userInitiated) {
        let socket = try ADBSocketConnection()
        try socket.sendTransport(to: reference.deviceId)
        try socket.sendLocalAbstract(reference.socketName)
        return socket
      }.value
      guard !Task.isCancelled else {
        socket.close()
        return
      }

      let connection = try NetworkInspectorConnection(
        socket: socket,
        serverKey: reference.key
      ) { [weak self] event in
        Task { await self?.handleConnectionEvent(event) }
      }
      servers[reference.key] = ServerState(
        reference: reference,
        connection: connection,
        deviceDisplayTitle: device.displayTitle,
        appInfo: nil,
        packageNameHint: nil
      )
      populatePackageNameHint(reference: reference, connection: connection)
    } catch {
      return
    }
  }

  private func populatePackageNameHint(
    reference: NetworkServerReference,
    connection: NetworkInspectorConnection
  ) {
    Task { [weak self, weak connection] in
      guard let packageName = await self?.packageNameHint(reference: reference),
            let self,
            let connection
      else {
        return
      }
      await setPackageNameHint(
        packageName,
        reference: reference,
        connection: connection
      )
    }
  }

  private func setPackageNameHint(
    _ packageName: String,
    reference: NetworkServerReference,
    connection: NetworkInspectorConnection
  ) {
    guard var state = servers[reference.key], state.connection === connection else { return }
    state.packageNameHint = packageName
    servers[reference.key] = state
  }

  private func networkSocketNames(deviceID: String) async throws -> [String] {
    let output = try await shell(deviceID: deviceID, command: "cat /proc/net/unix")
    return Array(
      Set(
        output
          .split(separator: "\n")
          .compactMap { $0.split(whereSeparator: \.isWhitespace).last }
          .compactMap { token -> String? in
            let name = String(token)
            guard name.hasPrefix("@snapo_network_") else { return nil }
            return String(name.dropFirst())
          }
      )
    ).sorted()
  }

  private func packageNameHint(reference: NetworkServerReference) async -> String? {
    guard let pid = Self.pid(socketName: reference.socketName) else { return nil }
    guard let output = try? await shell(
      deviceID: reference.deviceId,
      command: "cat /proc/\(pid)/cmdline 2>/dev/null"
    ) else {
      return nil
    }
    return output
      .split { $0 == "\0" || $0 == "\n" || $0 == "\r" }
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .first { !$0.isEmpty }
  }

  private func shell(deviceID: String, command: String) async throws -> String {
    try await Task.detached(priority: .utility) {
      let socket = try ADBSocketConnection()
      try socket.sendTransport(to: deviceID)
      try socket.sendShell(command)
      let data = try socket.readToEnd()
      return String(bytes: data, encoding: .utf8) ?? ""
    }.value
  }

  private func handleConnectionEvent(_ event: NetworkInspectorConnectionEvent) {
    switch event {
    case .closed(let serverKey, let message):
      removeServer(serverKey, message: message)
    case .record(let serverKey, let record):
      handleRecord(serverKey: serverKey, record: record)
    }
  }

  private func handleRecord(serverKey: String, record: NetworkServerRecord) {
    switch record {
    case .appInfo(let info):
      guard var state = servers[serverKey] else { return }
      state.appInfo = info
      servers[serverKey] = state
    case .network(let message):
      if message.method == nil, let id = message.id {
        let key = PendingCommandKey(serverKey: serverKey, id: id)
        if let continuation = pendingCommands.removeValue(forKey: key) {
          continuation.resume(returning: message)
          return
        }
      }
      guard let server = servers[serverKey]?.reference else { return }
      for (streamID, key) in streams where key == serverKey {
        emit(.event(NetworkStreamEvent(streamId: streamID, server: server, message: message)))
      }
    case .replayComplete, .unknown:
      break
    }
  }

  private func removeServer(_ key: String, message: String?) {
    guard let state = servers.removeValue(forKey: key) else { return }
    state.connection.close()

    let removedStreams = streams.filter { $0.value == key }.map(\.key)
    for streamID in removedStreams {
      streams.removeValue(forKey: streamID)
      emit(
        .status(
          NetworkStreamStatus(
            streamId: streamID,
            state: "exit",
            message: message ?? "Disconnected from \(state.reference.deviceId)/\(state.reference.socketName)",
            code: nil,
            signal: nil
          )
        )
      )
    }

    let pendingKeys = pendingCommands.keys.filter { $0.serverKey == key }
    for pendingKey in pendingKeys {
      pendingCommands.removeValue(forKey: pendingKey)?.resume(
        throwing: NetworkInspectorError.serverDisconnected
      )
    }
  }

  private func currentServers() -> [NetworkInspectorServer] {
    servers.values
      .map { state in
        let packageName = state.appInfo?.packageName ?? state.packageNameHint
        let protocolVersion = state.appInfo?.protocolVersion
        return NetworkInspectorServer(
          server: "\(state.reference.deviceId):\(state.reference.socketName)",
          deviceId: state.reference.deviceId,
          socketName: state.reference.socketName,
          deviceDisplayTitle: state.deviceDisplayTitle,
          displayName: packageName ?? state.reference.socketName,
          isConnected: true,
          hasAppInfo: state.appInfo != nil,
          pid: state.appInfo?.pid ?? Self.pid(socketName: state.reference.socketName),
          protocolVersion: protocolVersion,
          isProtocolNewerThanSupported: protocolVersion.map {
            $0 > Self.supportedProtocolVersion
          } ?? false,
          isProtocolOlderThanSupported: state.appInfo != nil && (
            protocolVersion.map { $0 < Self.supportedProtocolVersion } ?? true
          ),
          appIconBase64: state.appInfo?.icon?.base64Data,
          packageName: packageName,
          appName: state.appInfo?.processName.trimmingCharacters(in: .whitespacesAndNewlines)
        )
      }
      .sorted {
        if $0.deviceId != $1.deviceId { return $0.deviceId < $1.deviceId }
        return $0.socketName < $1.socketName
      }
  }

  private func emit(_ output: NetworkInspectorOutput) {
    for continuation in outputContinuations.values {
      continuation.yield(output)
    }
  }

  private func removeOutputContinuation(_ id: UUID) {
    outputContinuations.removeValue(forKey: id)
  }

  private static func pid(socketName: String) -> Int? {
    guard socketName.hasPrefix("snapo_network_") else { return nil }
    return Int(socketName.dropFirst("snapo_network_".count))
  }
}
