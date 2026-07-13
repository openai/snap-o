import Foundation
import SnapODeviceClient

actor NetworkInspectorService {
  private static let maximumBufferedOutputs = 4096
  private static let bodyCommandTimeout: Duration = .seconds(10)

  private struct ServerState {
    let reference: NetworkServerReference
    let connectionID: UUID
    let session: NetworkSession
    let recordTask: Task<Void, Never>
    var deviceDisplayTitle: String
    var appInfo: NetworkAppInfo?
    var packageNameHint: String?
  }

  private struct RefreshFlight {
    let id: UUID
    let task: Task<Void, Never>
  }

  private struct StreamStartFlight {
    let id: UUID
    let connectionID: UUID
    let task: Task<Void, Error>
  }

  private let adbService: ADBService
  private let deviceTracker: DeviceTracker

  private var servers: [String: ServerState] = [:]
  private var streams: [String: String] = [:]
  private var activeStreamConnections: [String: UUID] = [:]
  private var streamStartFlights: [String: StreamStartFlight] = [:]
  private var outputContinuations: [UUID: AsyncStream<NetworkInspectorOutput>.Continuation] = [:]
  private var refreshFlight: RefreshFlight?
  private var isStopped = false

  init(adbService: ADBService, deviceTracker: DeviceTracker) {
    self.adbService = adbService
    self.deviceTracker = deviceTracker
  }

  func outputStream() -> AsyncStream<NetworkInspectorOutput> {
    let id = UUID()
    return AsyncStream(bufferingPolicy: .bufferingOldest(Self.maximumBufferedOutputs)) { continuation in
      if isStopped {
        continuation.finish()
        return
      }
      outputContinuations[id] = continuation
      continuation.onTermination = { [weak self] _ in
        Task { await self?.removeOutputContinuation(id) }
      }
    }
  }

  func listServers() async -> [NetworkInspectorServer] {
    guard !isStopped else { return [] }
    await refresh()
    return currentServers()
  }

  func startStream(_ reference: NetworkServerReference) async throws -> NetworkStreamStarted {
    await refresh()
    guard !isStopped, let state = servers[reference.key] else {
      throw NetworkInspectorError.serverNotConnected(reference)
    }

    let streamID = UUID().uuidString
    streams[streamID] = reference.key

    let startFlight: StreamStartFlight?
    if activeStreamConnections[reference.key] == state.connectionID {
      startFlight = nil
    } else if let flight = streamStartFlights[reference.key],
              flight.connectionID == state.connectionID {
      startFlight = flight
    } else {
      streamStartFlights.removeValue(forKey: reference.key)?.task.cancel()
      let flight = StreamStartFlight(
        id: UUID(),
        connectionID: state.connectionID,
        task: Task {
          try await state.session.send(method: SnapONetworkProtocol.Method.startStream)
        }
      )
      streamStartFlights[reference.key] = flight
      startFlight = flight
    }

    do {
      if let startFlight {
        try await startFlight.task.value
        completeStartFlight(startFlight, serverKey: reference.key)
      }
      guard !isStopped,
            servers[reference.key]?.connectionID == state.connectionID,
            streams[streamID] == reference.key else {
        throw NetworkInspectorError.serverNotConnected(reference)
      }

      emit(
        .status(
          NetworkStreamStatus(
            streamId: streamID,
            state: "started",
            message: "Connected to \(reference.identifier)",
            code: nil,
            signal: nil
          )
        )
      )
      return NetworkStreamStarted(streamId: streamID)
    } catch {
      rollBackStreamStart(
        streamID: streamID,
        serverKey: reference.key,
        startFlight: startFlight
      )
      throw error
    }
  }

  func stopStream(_ streamID: String) async {
    guard let key = streams.removeValue(forKey: streamID) else { return }
    guard !streams.values.contains(key), let session = servers[key]?.session else { return }
    activeStreamConnections.removeValue(forKey: key)
    streamStartFlights.removeValue(forKey: key)?.task.cancel()
    try? await session.send(method: SnapONetworkProtocol.Method.stopStream)
  }

  func stopAllStreams() async {
    let serverKeys = Set(streams.values)
    streams.removeAll()
    activeStreamConnections.removeAll()
    let startFlights = Array(streamStartFlights.values)
    streamStartFlights.removeAll()
    for flight in startFlights {
      flight.task.cancel()
    }
    for serverKey in serverKeys {
      guard let session = servers[serverKey]?.session else { continue }
      try? await session.send(method: SnapONetworkProtocol.Method.stopStream)
    }
  }

  func loadBodies(_ input: NetworkLoadBodiesInput) async -> NetworkRequestBodies {
    let reference = NetworkServerReference(deviceId: input.deviceId, socketName: input.socketName)
    if let requestedInstanceID = input.serverInstanceId,
       requestedInstanceID != Self.instanceID(for: servers[reference.key]?.appInfo) {
      return NetworkRequestBodies(
        requestId: input.requestId,
        requestBody: nil,
        responseBody: nil,
        responseBodyBase64Encoded: nil
      )
    }

    async let requestMessage = optionalCommand(
      enabled: input.includeRequestBody ?? true,
      serverKey: reference.key,
      method: SnapONetworkProtocol.Method.getRequestPostData,
      requestID: input.requestId
    )
    async let responseMessage = optionalCommand(
      enabled: input.includeResponseBody ?? true,
      serverKey: reference.key,
      method: SnapONetworkProtocol.Method.getResponseBody,
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

  func stop() async {
    guard !isStopped else { return }
    isStopped = true
    refreshFlight?.task.cancel()
    refreshFlight = nil
    streams.removeAll()
    activeStreamConnections.removeAll()
    let startFlights = Array(streamStartFlights.values)
    streamStartFlights.removeAll()
    for flight in startFlights {
      flight.task.cancel()
    }

    let activeServers = Array(servers.values)
    servers.removeAll()
    for state in activeServers {
      state.recordTask.cancel()
      await state.session.close()
    }

    let continuations = Array(outputContinuations.values)
    outputContinuations.removeAll()
    for continuation in continuations {
      continuation.finish()
    }
  }

  func isRunning() -> Bool {
    !isStopped
  }

  private func optionalCommand(
    enabled: Bool,
    serverKey: String,
    method: String,
    requestID: String
  ) async -> NetworkCDPMessage? {
    guard enabled, let session = servers[serverKey]?.session else { return nil }
    return try? await session.command(
      method: method,
      params: ["requestId": .string(requestID)],
      timeout: Self.bodyCommandTimeout
    )
  }

  private func refresh() async {
    guard !isStopped else { return }
    if let refreshFlight {
      await refreshFlight.task.value
      return
    }

    let id = UUID()
    let task = Task<Void, Never> { [weak self] in
      await self?.refreshNow()
    }
    refreshFlight = RefreshFlight(id: id, task: task)
    await task.value
    if refreshFlight?.id == id {
      refreshFlight = nil
    }
  }

  private func refreshNow() async {
    let devices = await deviceTracker.latestDevices
    let adb = await adbService.exec()
    let references = await NetworkServerDiscovery.discover(
      on: devices.map(\.id),
      using: adb
    )
    guard !Task.isCancelled, !isStopped else { return }

    let devicesByID = Dictionary(uniqueKeysWithValues: devices.map { ($0.id, $0) })
    let seenKeys = Set(references.map(\.key))
    for reference in references {
      guard let device = devicesByID[reference.deviceId] else { continue }

      if var state = servers[reference.key] {
        state.deviceDisplayTitle = device.displayTitle
        servers[reference.key] = state
      } else {
        await connect(device: device, reference: reference, using: adb)
      }
      guard !Task.isCancelled, !isStopped else { return }
    }

    let removedKeys = servers.keys.filter { !seenKeys.contains($0) }
    for key in removedKeys {
      await removeServer(key, message: nil)
    }
  }

  private func connect(
    device: Device,
    reference: NetworkServerReference,
    using adb: ADBClient
  ) async {
    do {
      let session = try await NetworkSession.connect(
        to: reference,
        using: adb,
        defaultCommandTimeout: .milliseconds(1500)
      )
      guard !Task.isCancelled, !isStopped else {
        await session.close()
        return
      }

      let connectionID = UUID()
      let recordTask = Task { [weak self] in
        let records = await session.records()
        for await record in records {
          guard !Task.isCancelled else { return }
          await self?.handleRecord(
            serverKey: reference.key,
            connectionID: connectionID,
            record: record
          )
        }
        await self?.sessionDidEnd(serverKey: reference.key, connectionID: connectionID)
      }
      servers[reference.key] = ServerState(
        reference: reference,
        connectionID: connectionID,
        session: session,
        recordTask: recordTask,
        deviceDisplayTitle: device.displayTitle,
        appInfo: nil,
        packageNameHint: nil
      )
      populatePackageNameHint(reference: reference, connectionID: connectionID, using: adb)
    } catch {
      return
    }
  }

  private func populatePackageNameHint(
    reference: NetworkServerReference,
    connectionID: UUID,
    using adb: ADBClient
  ) {
    Task { [weak self] in
      guard let packageName = await NetworkServerDiscovery.packageNameHint(
        for: reference,
        using: adb
      )
      else {
        return
      }
      await self?.setPackageNameHint(
        packageName,
        reference: reference,
        connectionID: connectionID
      )
    }
  }

  private func setPackageNameHint(
    _ packageName: String,
    reference: NetworkServerReference,
    connectionID: UUID
  ) {
    guard var state = servers[reference.key], state.connectionID == connectionID else { return }
    state.packageNameHint = packageName
    servers[reference.key] = state
  }

  private func handleRecord(
    serverKey: String,
    connectionID: UUID,
    record: NetworkServerRecord
  ) {
    guard var state = servers[serverKey], state.connectionID == connectionID else { return }

    switch record {
    case .appInfo(let info):
      state.appInfo = info
      servers[serverKey] = state
    case .network(let message):
      for (streamID, key) in streams where key == serverKey {
        emit(
          .event(
            NetworkStreamEvent(
              streamId: streamID,
              server: state.reference,
              serverInstanceId: Self.instanceID(for: state.appInfo),
              message: message
            )
          )
        )
      }
    case .replayComplete, .unknown:
      break
    }
  }

  private func sessionDidEnd(serverKey: String, connectionID: UUID) async {
    guard servers[serverKey]?.connectionID == connectionID else { return }
    await removeServer(serverKey, message: nil)
  }

  private func removeServer(_ key: String, message: String?) async {
    guard let state = servers.removeValue(forKey: key) else { return }
    activeStreamConnections.removeValue(forKey: key)
    streamStartFlights.removeValue(forKey: key)?.task.cancel()
    state.recordTask.cancel()
    await state.session.close()

    let removedStreams = streams.filter { $0.value == key }.map(\.key)
    for streamID in removedStreams {
      streams.removeValue(forKey: streamID)
      emit(
        .status(
          NetworkStreamStatus(
            streamId: streamID,
            state: "exit",
            message: message ?? "Disconnected from \(state.reference.identifier)",
            code: nil,
            signal: nil
          )
        )
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
          pid: state.appInfo?.pid ?? NetworkServerDiscovery.pid(
            inSocketName: state.reference.socketName
          ),
          protocolVersion: protocolVersion,
          isProtocolNewerThanSupported: protocolVersion.map {
            $0 > SnapONetworkProtocol.supportedVersion
          } ?? false,
          isProtocolOlderThanSupported: state.appInfo != nil && (
            protocolVersion.map { $0 < SnapONetworkProtocol.supportedVersion } ?? true
          ),
          appIconBase64: state.appInfo?.icon?.base64Data,
          packageName: packageName,
          appName: state.appInfo?.processName.trimmingCharacters(in: .whitespacesAndNewlines),
          instanceId: Self.instanceID(for: state.appInfo)
        )
      }
      .sorted {
        if $0.deviceId != $1.deviceId { return $0.deviceId < $1.deviceId }
        return $0.socketName < $1.socketName
      }
  }

  private func emit(_ output: NetworkInspectorOutput) {
    var overflowedContinuationIDs: [UUID] = []
    for (id, continuation) in outputContinuations {
      if case .dropped = continuation.yield(output) {
        overflowedContinuationIDs.append(id)
      }
    }
    for id in overflowedContinuationIDs {
      // Stream termination is an explicit recovery signal to the host model.
      // Continuing after dropping an event would leave the web state incomplete.
      outputContinuations.removeValue(forKey: id)?.finish()
    }
  }

  private func completeStartFlight(_ flight: StreamStartFlight, serverKey: String) {
    guard streamStartFlights[serverKey]?.id == flight.id else { return }
    streamStartFlights.removeValue(forKey: serverKey)
    guard servers[serverKey]?.connectionID == flight.connectionID,
          streams.values.contains(serverKey) else { return }
    activeStreamConnections[serverKey] = flight.connectionID
  }

  private func rollBackStreamStart(
    streamID: String,
    serverKey: String,
    startFlight: StreamStartFlight?
  ) {
    streams.removeValue(forKey: streamID)
    if let startFlight, streamStartFlights[serverKey]?.id == startFlight.id {
      streamStartFlights.removeValue(forKey: serverKey)
    }
    if !streams.values.contains(serverKey) {
      activeStreamConnections.removeValue(forKey: serverKey)
    }
  }

  private func removeOutputContinuation(_ id: UUID) {
    outputContinuations.removeValue(forKey: id)
  }

  private static func instanceID(for appInfo: NetworkAppInfo?) -> String? {
    guard let appInfo else { return nil }
    return "\(appInfo.serverStartWallMs):\(appInfo.serverStartMonoNs)"
  }
}
