import Foundation

actor NetworkInspectorService {
  private struct ServerState {
    var server: NetworkInspectorServer
    var forwardHandle: ADBForwardHandle
    var connection: NetworkServerConnection?
  }

  private let adbService: ADBService
  private let deviceTracker: DeviceTracker

  private var isStarted = false
  private var deviceStreamTask: Task<Void, Never>?
  private var deviceMonitors: [String: Task<Void, Never>] = [:]
  private var deviceSockets: [String: Set<String>] = [:]
  private var serverStates: [NetworkInspectorServer.ID: ServerState] = [:]
  private var events: [NetworkInspectorEvent] = []
  private var serverContinuations: [UUID: AsyncStream<[NetworkInspectorServer]>.Continuation] = [:]
  private var eventContinuations: [UUID: AsyncStream<NetworkInspectorEvent>.Continuation] = [:]
  private var requestStates: [NetworkInspectorRequest.ID: NetworkInspectorRequest] = [:]
  private var requestOrder: [NetworkInspectorRequest.ID] = []
  private var requestContinuations: [UUID: AsyncStream<[NetworkInspectorRequest]>.Continuation] = [:]

  init(adbService: ADBService, deviceTracker: DeviceTracker) {
    self.adbService = adbService
    self.deviceTracker = deviceTracker
  }

  deinit {
    deviceStreamTask?.cancel()
    for monitor in deviceMonitors.values {
      monitor.cancel()
    }
    for state in serverStates.values {
      state.connection?.stop()
    }
  }

  func start() async {
    guard !isStarted else { return }
    isStarted = true

    await updateDevices(deviceTracker.latestDevices)

    deviceStreamTask = Task.detached(priority: .utility) { [deviceTracker] in
      let stream = deviceTracker.deviceStream()
      for await devices in stream {
        await self.updateDevices(devices)
      }
    }
  }

  func serversStream() -> AsyncStream<[NetworkInspectorServer]> {
    let id = UUID()
    return AsyncStream { continuation in
      serverContinuations[id] = continuation
      continuation.yield(currentServers())
      continuation.onTermination = { [weak self] _ in
        Task { await self?.removeServerContinuation(id) }
      }
    }
  }

  func eventsStream() -> AsyncStream<NetworkInspectorEvent> {
    let id = UUID()
    return AsyncStream { continuation in
      eventContinuations[id] = continuation
      for event in events {
        continuation.yield(event)
      }
      continuation.onTermination = { [weak self] _ in
        Task { await self?.removeEventContinuation(id) }
      }
    }
  }

  func requestsStream() -> AsyncStream<[NetworkInspectorRequest]> {
    let id = UUID()
    return AsyncStream { continuation in
      requestContinuations[id] = continuation
      continuation.yield(currentRequests())
      continuation.onTermination = { [weak self] _ in
        Task { await self?.removeRequestContinuation(id) }
      }
    }
  }

  private func removeServerContinuation(_ id: UUID) {
    serverContinuations.removeValue(forKey: id)
  }

  private func removeEventContinuation(_ id: UUID) {
    eventContinuations.removeValue(forKey: id)
  }

  private func removeRequestContinuation(_ id: UUID) {
    requestContinuations.removeValue(forKey: id)
  }

  private func updateDevices(_ devices: [Device]) async {
    let active = Set(devices.map(\.id))
    let known = Set(deviceMonitors.keys)

    for id in active where !known.contains(id) {
      await startMonitoringDevice(id)
    }

    for id in known where !active.contains(id) {
      await stopMonitoringDevice(id)
    }
  }

  private func startMonitoringDevice(_ deviceID: String) async {
    guard deviceMonitors[deviceID] == nil else { return }
    let adb = adbService
    let task = Task.detached(priority: .utility) { [deviceID] in
      while !Task.isCancelled {
        do {
          let exec = await adb.exec()
          let output = try await exec.listUnixSockets(deviceID: deviceID)
          let sockets = Self.parseServers(from: output)
          await self.handleSocketsUpdate(deviceID: deviceID, sockets: sockets)
        } catch is CancellationError {
          break
        } catch {
          SnapOLog.network.error(
            "Socket poll failed for \(deviceID, privacy: .public): \(error.localizedDescription, privacy: .public)"
          )
          await self.handleSocketsUpdate(deviceID: deviceID, sockets: [])
        }
        try? await Task.sleep(for: .seconds(2))
      }
    }
    deviceMonitors[deviceID] = task
  }

  private func stopMonitoringDevice(_ deviceID: String) async {
    if let task = deviceMonitors.removeValue(forKey: deviceID) {
      task.cancel()
    }
    deviceSockets[deviceID] = Set()
    let idsToRemove = serverStates.keys.filter { $0.deviceID == deviceID }
    for id in idsToRemove {
      await removeServer(id)
    }
    broadcastServers()
  }

  private func handleSocketsUpdate(deviceID: String, sockets: Set<String>) async {
    let previous = deviceSockets[deviceID] ?? Set()
    if previous == sockets { return }
    deviceSockets[deviceID] = sockets

    let added = sockets.subtracting(previous)
    let removed = previous.subtracting(sockets)

    for socket in added {
      await startServerConnection(deviceID: deviceID, socketName: socket)
    }

    for socket in removed {
      await stopServerConnection(deviceID: deviceID, socketName: socket)
    }
  }

  private func startServerConnection(deviceID: String, socketName: String) async {
    let exec = await adbService.exec()
    do {
      let handle = try await exec.forwardLocalAbstract(deviceID: deviceID, abstractSocket: socketName)
      let serverID = NetworkInspectorServer.ID(deviceID: deviceID, socketName: socketName)
      let server = NetworkInspectorServer(
        deviceID: deviceID,
        socketName: socketName,
        localPort: handle.port,
        hello: nil,
        lastEventAt: nil
      )
      let connection = NetworkServerConnection(
        port: handle.port,
        queueLabel: "com.openai.snapo.netinspector.\(deviceID).\(socketName)",
        onEvent: { record in
          Task { await self.handle(record: record, from: serverID) }
        },
        onClose: { error in
          Task { await self.connectionClosed(for: serverID, error: error) }
        }
      )
      serverStates[serverID] = ServerState(server: server, forwardHandle: handle, connection: connection)
      broadcastServers()
      connection.start()
    } catch {
      SnapOLog.network.error(
        "Failed to connect to \(socketName, privacy: .public) on \(deviceID, privacy: .public): \(error.localizedDescription, privacy: .public)"
      )
      deviceSockets[deviceID]?.remove(socketName)
    }
  }

  private func stopServerConnection(deviceID: String, socketName: String) async {
    let serverID = NetworkInspectorServer.ID(deviceID: deviceID, socketName: socketName)
    await removeServer(serverID)
  }

  private func removeServer(_ id: NetworkInspectorServer.ID) async {
    guard let state = serverStates.removeValue(forKey: id) else { return }
    state.connection?.stop()
    await removeForward(state.forwardHandle)
    if var sockets = deviceSockets[id.deviceID] {
      sockets.remove(id.socketName)
      deviceSockets[id.deviceID] = sockets
    }
    broadcastServers()
    removeRequests(for: id)
  }

  private func removeForward(_ handle: ADBForwardHandle) async {
    let exec = await adbService.exec()
    await exec.removeForward(handle)
  }

  private func handle(record: SnapONetRecord, from serverID: NetworkInspectorServer.ID) async {
    guard var state = serverStates[serverID] else { return }
    var shouldBroadcastServers = false
    var shouldBroadcastRequests = false

    switch record {
    case .hello(let hello):
      state.server.hello = hello
      shouldBroadcastServers = true
    case .requestWillBeSent(let requestRecord):
      shouldBroadcastRequests = updateRequest(for: serverID, with: requestRecord)
    case .responseReceived(let responseRecord):
      shouldBroadcastRequests = updateRequest(for: serverID, with: responseRecord)
    case .requestFailed(let failureRecord):
      shouldBroadcastRequests = updateRequest(for: serverID, with: failureRecord)
    default:
      break
    }

    state.server.lastEventAt = Date()
    serverStates[serverID] = state

    if shouldBroadcastServers {
      broadcastServers()
    }

    if shouldBroadcastRequests {
      broadcastRequests()
    }

    let event = NetworkInspectorEvent(
      serverID: serverID,
      record: record,
      receivedAt: Date()
    )
    events.append(event)
    broadcast(event: event)
  }

  private func connectionClosed(for serverID: NetworkInspectorServer.ID, error: Error?) async {
    if let error {
      SnapOLog.network.error(
        "Connection closed for \(serverID.deviceID, privacy: .public)/\(serverID.socketName, privacy: .public): \(error.localizedDescription, privacy: .public)"
      )
    }
    await removeServer(serverID)
  }

  private func broadcastServers() {
    let snapshot = currentServers()
    for continuation in serverContinuations.values {
      continuation.yield(snapshot)
    }
  }

  private func broadcast(event: NetworkInspectorEvent) {
    for continuation in eventContinuations.values {
      continuation.yield(event)
    }
  }

  private func broadcastRequests() {
    let snapshot = currentRequests()
    for continuation in requestContinuations.values {
      continuation.yield(snapshot)
    }
  }

  private func currentServers() -> [NetworkInspectorServer] {
    serverStates.values.map(\.server).sorted { lhs, rhs in
      if lhs.deviceID == rhs.deviceID {
        return lhs.socketName < rhs.socketName
      }
      return lhs.deviceID < rhs.deviceID
    }
  }

  private func currentRequests() -> [NetworkInspectorRequest] {
    requestOrder.compactMap { requestStates[$0] }
  }

  private func removeRequests(for serverID: NetworkInspectorServer.ID) {
    requestOrder.removeAll { $0.serverID == serverID }
    requestStates = requestStates.filter { key, _ in key.serverID != serverID }
    broadcastRequests()
  }

  private func updateRequest(for serverID: NetworkInspectorServer.ID, with record: SnapONetRequestWillBeSentRecord) -> Bool {
    let timestamp = Date()
    let identifier = NetworkInspectorRequest.ID(serverID: serverID, requestID: record.id)
    var updated = requestStates[identifier]

    if updated == nil {
      updated = NetworkInspectorRequest(serverID: serverID, request: record, timestamp: timestamp)
      requestOrder.append(identifier)
    } else {
      updated?.request = record
      updated?.failure = nil
    }

    updated?.lastUpdatedAt = timestamp
    if let updated {
      requestStates[identifier] = updated
      return true
    }
    return false
  }

  private func updateRequest(for serverID: NetworkInspectorServer.ID, with record: SnapONetResponseReceivedRecord) -> Bool {
    let timestamp = Date()
    let identifier = NetworkInspectorRequest.ID(serverID: serverID, requestID: record.id)
    var updated = requestStates[identifier]

    if updated == nil {
      updated = NetworkInspectorRequest(serverID: serverID, requestID: record.id, timestamp: timestamp)
      requestOrder.append(identifier)
    }

    updated?.response = record
    updated?.failure = nil
    updated?.lastUpdatedAt = timestamp

    if let updated {
      requestStates[identifier] = updated
      return true
    }
    return false
  }

  private func updateRequest(for serverID: NetworkInspectorServer.ID, with record: SnapONetRequestFailedRecord) -> Bool {
    let timestamp = Date()
    let identifier = NetworkInspectorRequest.ID(serverID: serverID, requestID: record.id)
    var updated = requestStates[identifier]

    if updated == nil {
      updated = NetworkInspectorRequest(serverID: serverID, requestID: record.id, timestamp: timestamp)
      requestOrder.append(identifier)
    }

    updated?.failure = record
    updated?.response = nil
    updated?.lastUpdatedAt = timestamp

    if let updated {
      requestStates[identifier] = updated
      return true
    }
    return false
  }

  private static func parseServers(from output: String) -> Set<String> {
    var result: Set<String> = []
    for line in output.split(whereSeparator: \.isNewline) {
      let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else { continue }
      let parts = trimmed.split(whereSeparator: \.isWhitespace)
      guard let token = parts.last, token.hasPrefix("@snapo_server_") else { continue }
      let name = String(token.dropFirst())
      result.insert(name)
    }
    return result
  }
}
