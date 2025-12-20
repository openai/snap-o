import Foundation

actor NetworkInspectorService {
  private struct ServerState {
    var server: SnapOLinkServer
    var forwardHandle: ADBForwardHandle?
    var connection: SnapOLinkServerConnection?
  }

  private let adbService: ADBService
  private let deviceTracker: DeviceTracker

  private var isStarted = false
  private var deviceStreamTask: Task<Void, Never>?
  private var deviceMonitors: [String: Task<Void, Never>] = [:]
  private var deviceSockets: [String: Set<String>] = [:]
  private var devices: [String: Device] = [:]
  private var serverStates: [SnapOLinkServerID: ServerState] = [:]
  private var events: [SnapOLinkEvent] = []
  private var serverContinuations: [UUID: AsyncStream<[SnapOLinkServer]>.Continuation] = [:]
  private var eventContinuations: [UUID: AsyncStream<SnapOLinkEvent>.Continuation] = [:]
  private var requestStates: [NetworkInspectorRequestID: NetworkInspectorRequest] = [:]
  private var requestOrder: [NetworkInspectorRequestID] = []
  private var requestContinuations: [UUID: AsyncStream<[NetworkInspectorRequest]>.Continuation] = [:]
  private var webSocketStates: [NetworkInspectorWebSocketID: NetworkInspectorWebSocket] = [:]
  private var webSocketOrder: [NetworkInspectorWebSocketID] = []
  private var webSocketContinuations: [UUID: AsyncStream<[NetworkInspectorWebSocket]>.Continuation] = [:]
  private var retainedServerIDs: Set<SnapOLinkServerID> = []
  private static let supportedSchemaVersion = SnapONetRecordDecoder.supportedSchemaVersion

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

  func updateRetainedServers(_ ids: Set<SnapOLinkServerID>) async {
    retainedServerIDs = ids
    await purgeUnretainedDisconnectedServers()
  }

  func serversStream() -> AsyncStream<[SnapOLinkServer]> {
    let id = UUID()
    return AsyncStream { continuation in
      serverContinuations[id] = continuation
      continuation.yield(currentServers())
      continuation.onTermination = { [weak self] _ in
        Task { await self?.removeServerContinuation(id) }
      }
    }
  }

  func eventsStream() -> AsyncStream<SnapOLinkEvent> {
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

  func webSocketsStream() -> AsyncStream<[NetworkInspectorWebSocket]> {
    let id = UUID()
    return AsyncStream { continuation in
      webSocketContinuations[id] = continuation
      continuation.yield(currentWebSockets())
      continuation.onTermination = { [weak self] _ in
        Task { await self?.removeWebSocketContinuation(id) }
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

  private func removeWebSocketContinuation(_ id: UUID) {
    webSocketContinuations.removeValue(forKey: id)
  }

  private func updateDevices(_ devices: [Device]) async {
    let active = Set(devices.map(\.id))
    self.devices = Dictionary(uniqueKeysWithValues: devices.map { ($0.id, $0) })
    let known = Set(deviceMonitors.keys)

    for id in active where !known.contains(id) {
      await startMonitoringDevice(id)
    }

    for id in known where !active.contains(id) {
      await stopMonitoringDevice(id)
    }

    var didUpdateServers = false
    for (id, var state) in serverStates {
      let newTitle = self.devices[id.deviceID]?.displayTitle ?? id.deviceID
      if state.server.deviceDisplayTitle != newTitle {
        state.server.deviceDisplayTitle = newTitle
        serverStates[id] = state
        didUpdateServers = true
      }
    }

    if didUpdateServers {
      broadcastServers()
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
      let serverID = SnapOLinkServerID(deviceID: deviceID, socketName: socketName)
      var server = SnapOLinkServer(
        deviceID: deviceID,
        socketName: socketName,
        localPort: handle.port,
        hello: nil,
        schemaVersion: serverStates[serverID]?.server.schemaVersion,
        isSchemaNewerThanSupported: serverStates[serverID]?.server.isSchemaNewerThanSupported ?? false,
        lastEventAt: nil,
        deviceDisplayTitle: devices[deviceID]?.displayTitle ?? deviceID,
        isConnected: true,
        appIcon: serverStates[serverID]?.server.appIcon,
        wallClockBase: serverStates[serverID]?.server.wallClockBase,
        packageNameHint: serverStates[serverID]?.server.packageNameHint
      )
      if let existing = serverStates[serverID]?.server {
        server.hello = existing.hello
        server.lastEventAt = existing.lastEventAt
      }
      let connection = SnapOLinkServerConnection(
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
      if server.hello == nil {
        await populatePackageNameHint(for: serverID, deviceID: deviceID, socketName: socketName)
      }
    } catch {
      SnapOLog.network.error(
        """
        Failed to connect to \(socketName, privacy: .public) on \(deviceID, privacy: .public):
        \(error.localizedDescription, privacy: .public)
        """
      )
      deviceSockets[deviceID]?.remove(socketName)
    }
  }

  private func populatePackageNameHint(
    for serverID: SnapOLinkServerID,
    deviceID: String,
    socketName: String
  ) async {
    guard let pid = Self.pid(fromSocketName: socketName) else { return }
    let exec = await adbService.exec()
    let command = "cat /proc/\(pid)/cmdline 2>/dev/null"

    guard let output = try? await exec.runShellString(deviceID: deviceID, command: command) else {
      return
    }

    let separator = Character(UnicodeScalar(0))
    let components = output.split(separator: separator, omittingEmptySubsequences: true)
    let fallback = output.split { $0.isNewline }.first
    var candidate = components.first.map(String.init)
      ?? fallback.map(String.init)

    candidate = candidate?.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)

    guard let name = candidate, !name.isEmpty else { return }

    if var state = serverStates[serverID] {
      if state.server.packageNameHint != name {
        state.server.packageNameHint = name
        serverStates[serverID] = state
        broadcastServers()
      }
    }
  }

  private static func pid(fromSocketName socketName: String) -> Int? {
    let prefix = "snapo_server_"
    guard socketName.hasPrefix(prefix) else { return nil }
    let suffix = socketName.dropFirst(prefix.count)
    guard !suffix.isEmpty, suffix.allSatisfy(\.isNumber) else { return nil }
    return Int(suffix)
  }

  private func stopServerConnection(deviceID: String, socketName: String) async {
    let serverID = SnapOLinkServerID(deviceID: deviceID, socketName: socketName)
    await removeServer(serverID)
  }

  private func removeServer(_ id: SnapOLinkServerID, force: Bool = false) async {
    guard var state = serverStates[id] else { return }
    state.connection?.stop()
    await removeForward(state.forwardHandle)
    state.connection = nil
    state.forwardHandle = nil

    if var sockets = deviceSockets[id.deviceID] {
      sockets.remove(id.socketName)
      deviceSockets[id.deviceID] = sockets
    }

    let shouldRetain = !force && retainedServerIDs.contains(id)

    if shouldRetain {
      state.server.isConnected = false
      serverStates[id] = state
      broadcastServers()
    } else {
      serverStates.removeValue(forKey: id)
      broadcastServers()
      removeRequests(for: id)
      removeWebSockets(for: id)
    }
  }

  private func removeForward(_ handle: ADBForwardHandle?) async {
    guard let handle else { return }
    let exec = await adbService.exec()
    await exec.removeForward(handle)
  }

  private func handle(record: SnapONetRecord, from serverID: SnapOLinkServerID) async {
    let now = Date()
    guard serverStates[serverID] != nil else { return }
    var shouldBroadcastServers = false
    var shouldBroadcastRequests = false
    var shouldBroadcastWebSockets = false

    switch record {
    case .hello(let hello):
      if var state = serverStates[serverID] {
        state.server.hello = hello
        state.server.schemaVersion = hello.schemaVersion
        state.server.isSchemaNewerThanSupported = Self.schemaVersionIsNewerThanSupported(hello.schemaVersion)
        state.server.features = Set(hello.features.map(\.id))
        state.server.wallClockBase = Date(timeIntervalSince1970: 0)
        state.server.lastEventAt = now
        serverStates[serverID] = state
        shouldBroadcastServers = true
      }
    case .requestWillBeSent(let requestRecord):
      shouldBroadcastRequests = updateRequest(for: serverID, with: requestRecord)
    case .responseReceived(let responseRecord):
      shouldBroadcastRequests = updateRequest(for: serverID, with: responseRecord)
    case .requestFailed(let failureRecord):
      shouldBroadcastRequests = updateRequest(for: serverID, with: failureRecord)
    case .responseStreamEvent(let eventRecord):
      shouldBroadcastRequests = updateRequest(for: serverID, with: eventRecord)
    case .responseStreamClosed(let closedRecord):
      shouldBroadcastRequests = updateRequest(for: serverID, with: closedRecord)
    case .appIcon(let iconRecord):
      shouldBroadcastServers = updateAppIcon(for: serverID, with: iconRecord)
    case .webSocketWillOpen(let willOpenRecord):
      shouldBroadcastWebSockets = updateWebSocket(for: serverID, with: willOpenRecord)
    case .webSocketOpened(let openedRecord):
      shouldBroadcastWebSockets = updateWebSocket(for: serverID, with: openedRecord)
    case .webSocketMessageSent(let sentRecord):
      shouldBroadcastWebSockets = updateWebSocket(for: serverID, with: sentRecord)
    case .webSocketMessageReceived(let receivedRecord):
      shouldBroadcastWebSockets = updateWebSocket(for: serverID, with: receivedRecord)
    case .webSocketClosing(let closingRecord):
      shouldBroadcastWebSockets = updateWebSocket(for: serverID, with: closingRecord)
    case .webSocketClosed(let closedRecord):
      shouldBroadcastWebSockets = updateWebSocket(for: serverID, with: closedRecord)
    case .webSocketFailed(let failedRecord):
      shouldBroadcastWebSockets = updateWebSocket(for: serverID, with: failedRecord)
    case .webSocketCloseRequested(let closeRequestedRecord):
      shouldBroadcastWebSockets = updateWebSocket(for: serverID, with: closeRequestedRecord)
    case .webSocketCancelled(let cancelledRecord):
      shouldBroadcastWebSockets = updateWebSocket(for: serverID, with: cancelledRecord)
    default:
      break
    }

    if var latestState = serverStates[serverID] {
      latestState.server.lastEventAt = now
      serverStates[serverID] = latestState
    }

    if shouldBroadcastServers {
      broadcastServers()
    }

    if shouldBroadcastRequests {
      broadcastRequests()
    }

    if shouldBroadcastWebSockets {
      broadcastWebSockets()
    }

    let event = SnapOLinkEvent(
      serverID: serverID,
      record: record,
      receivedAt: Date()
    )
    events.append(event)
    broadcast(event: event)
  }

  private func connectionClosed(for serverID: SnapOLinkServerID, error: Error?) async {
    if let error {
      SnapOLog.network.error(
        """
        Connection closed for \(serverID.deviceID, privacy: .public)/\(serverID.socketName, privacy: .public):
        \(error.localizedDescription, privacy: .public)
        """
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

  private func broadcast(event: SnapOLinkEvent) {
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

  private func broadcastWebSockets() {
    let snapshot = currentWebSockets()
    for continuation in webSocketContinuations.values {
      continuation.yield(snapshot)
    }
  }

  private func currentServers() -> [SnapOLinkServer] {
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

  private func currentWebSockets() -> [NetworkInspectorWebSocket] {
    webSocketOrder.compactMap { webSocketStates[$0] }
  }

  private func purgeUnretainedDisconnectedServers() async {
    let idsToRemove = serverStates.compactMap { id, state in
      (!retainedServerIDs.contains(id) && state.server.isConnected == false) ? id : nil
    }

    for id in idsToRemove {
      await removeServer(id, force: true)
    }
  }

  private func removeRequests(for serverID: SnapOLinkServerID) {
    requestOrder.removeAll { $0.serverID == serverID }
    requestStates = requestStates.filter { key, _ in key.serverID != serverID }
    broadcastRequests()
  }

  private func removeWebSockets(for serverID: SnapOLinkServerID) {
    webSocketOrder.removeAll { $0.serverID == serverID }
    webSocketStates = webSocketStates.filter { key, _ in key.serverID != serverID }
    broadcastWebSockets()
  }

  private func updateRequest(for serverID: SnapOLinkServerID, with record: SnapONetRequestWillBeSentRecord) -> Bool {
    let timestamp = Date()
    let identifier = NetworkInspectorRequestID(serverID: serverID, requestID: record.id)
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

  private func updateAppIcon(
    for serverID: SnapOLinkServerID,
    with record: SnapONetAppIconRecord
  ) -> Bool {
    guard var state = serverStates[serverID] else { return false }
    let currentPackage = state.server.hello?.packageName
    guard currentPackage == nil || currentPackage == record.packageName else { return false }

    if state.server.appIcon?.base64Data == record.base64Data {
      return false
    }

    guard Data(base64Encoded: record.base64Data) != nil else { return false }

    state.server.appIcon = record
    serverStates[serverID] = state
    return true
  }

  private func updateRequest(for serverID: SnapOLinkServerID, with record: SnapONetResponseReceivedRecord) -> Bool {
    let timestamp = Date()
    let identifier = NetworkInspectorRequestID(serverID: serverID, requestID: record.id)
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

  private func updateRequest(for serverID: SnapOLinkServerID, with record: SnapONetRequestFailedRecord) -> Bool {
    let timestamp = Date()
    let identifier = NetworkInspectorRequestID(serverID: serverID, requestID: record.id)
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

  private func updateRequest(for serverID: SnapOLinkServerID, with record: SnapONetResponseStreamEventRecord) -> Bool {
    let timestamp = Date()
    let identifier = NetworkInspectorRequestID(serverID: serverID, requestID: record.id)
    var updated = requestStates[identifier]

    if updated == nil {
      updated = NetworkInspectorRequest(serverID: serverID, requestID: record.id, timestamp: timestamp)
      requestOrder.append(identifier)
    }

    if var request = updated {
      if let existingIndex = request.streamEvents.firstIndex(where: { $0.sequence == record.sequence }) {
        request.streamEvents[existingIndex] = record
      } else {
        request.streamEvents.append(record)
        request.streamEvents.sort { lhs, rhs in
          if lhs.sequence == rhs.sequence {
            return lhs.tWallMs < rhs.tWallMs
          }
          return lhs.sequence < rhs.sequence
        }
      }
      request.lastUpdatedAt = timestamp
      requestStates[identifier] = request
      return true
    }

    return false
  }

  private func updateRequest(for serverID: SnapOLinkServerID, with record: SnapONetResponseStreamClosedRecord) -> Bool {
    let timestamp = Date()
    let identifier = NetworkInspectorRequestID(serverID: serverID, requestID: record.id)
    var updated = requestStates[identifier]

    if updated == nil {
      updated = NetworkInspectorRequest(serverID: serverID, requestID: record.id, timestamp: timestamp)
      requestOrder.append(identifier)
    }

    if var request = updated {
      request.streamClosed = record
      request.lastUpdatedAt = timestamp
      requestStates[identifier] = request
      return true
    }

    return false
  }

  private func updateWebSocket(
    for serverID: SnapOLinkServerID,
    with record: SnapONetWebSocketWillOpenRecord
  ) -> Bool {
    let timestamp = Date()
    let identifier = NetworkInspectorWebSocketID(serverID: serverID, socketID: record.id)
    var updated = webSocketStates[identifier]

    if updated == nil {
      updated = NetworkInspectorWebSocket(serverID: serverID, willOpen: record, timestamp: timestamp)
      webSocketOrder.append(identifier)
    } else {
      updated?.willOpen = record
    }

    updated?.failed = nil
    updated?.lastUpdatedAt = timestamp

    if let updated {
      webSocketStates[identifier] = updated
      return true
    }
    return false
  }

  private func updateWebSocket(
    for serverID: SnapOLinkServerID,
    with record: SnapONetWebSocketOpenedRecord
  ) -> Bool {
    let timestamp = Date()
    let identifier = NetworkInspectorWebSocketID(serverID: serverID, socketID: record.id)
    var updated = webSocketStates[identifier]

    if updated == nil {
      var session = NetworkInspectorWebSocket(serverID: serverID, socketID: record.id, timestamp: timestamp)
      session.opened = record
      updated = session
      webSocketOrder.append(identifier)
    } else {
      updated?.opened = record
    }

    updated?.failed = nil
    updated?.lastUpdatedAt = timestamp

    if let updated {
      webSocketStates[identifier] = updated
      return true
    }
    return false
  }

  private func updateWebSocket(
    for serverID: SnapOLinkServerID,
    with record: SnapONetWebSocketMessageSentRecord
  ) -> Bool {
    let timestamp = Date()
    let identifier = NetworkInspectorWebSocketID(serverID: serverID, socketID: record.id)
    var updated = webSocketStates[identifier]

    if updated == nil {
      var session = NetworkInspectorWebSocket(serverID: serverID, socketID: record.id, timestamp: timestamp)
      session.messages.append(SnapONetWebSocketMessage(sent: record))
      updated = session
      webSocketOrder.append(identifier)
    } else {
      updated?.messages.append(SnapONetWebSocketMessage(sent: record))
    }

    updated?.messages.sort { lhs, rhs in
      if lhs.tWallMs == rhs.tWallMs {
        return lhs.tMonoNs < rhs.tMonoNs
      }
      return lhs.tWallMs < rhs.tWallMs
    }

    updated?.lastUpdatedAt = timestamp

    if let updated {
      webSocketStates[identifier] = updated
      return true
    }
    return false
  }

  private func updateWebSocket(
    for serverID: SnapOLinkServerID,
    with record: SnapONetWebSocketMessageReceivedRecord
  ) -> Bool {
    let timestamp = Date()
    let identifier = NetworkInspectorWebSocketID(serverID: serverID, socketID: record.id)
    var updated = webSocketStates[identifier]

    if updated == nil {
      var session = NetworkInspectorWebSocket(serverID: serverID, socketID: record.id, timestamp: timestamp)
      session.messages.append(SnapONetWebSocketMessage(received: record))
      updated = session
      webSocketOrder.append(identifier)
    } else {
      updated?.messages.append(SnapONetWebSocketMessage(received: record))
    }

    updated?.messages.sort { lhs, rhs in
      if lhs.tWallMs == rhs.tWallMs {
        return lhs.tMonoNs < rhs.tMonoNs
      }
      return lhs.tWallMs < rhs.tWallMs
    }

    updated?.lastUpdatedAt = timestamp

    if let updated {
      webSocketStates[identifier] = updated
      return true
    }
    return false
  }

  private func updateWebSocket(
    for serverID: SnapOLinkServerID,
    with record: SnapONetWebSocketClosingRecord
  ) -> Bool {
    let timestamp = Date()
    let identifier = NetworkInspectorWebSocketID(serverID: serverID, socketID: record.id)
    var updated = webSocketStates[identifier]

    if updated == nil {
      var session = NetworkInspectorWebSocket(serverID: serverID, socketID: record.id, timestamp: timestamp)
      session.closing = record
      updated = session
      webSocketOrder.append(identifier)
    } else {
      updated?.closing = record
    }

    updated?.lastUpdatedAt = timestamp

    if let updated {
      webSocketStates[identifier] = updated
      return true
    }
    return false
  }

  private func updateWebSocket(
    for serverID: SnapOLinkServerID,
    with record: SnapONetWebSocketClosedRecord
  ) -> Bool {
    let timestamp = Date()
    let identifier = NetworkInspectorWebSocketID(serverID: serverID, socketID: record.id)
    var updated = webSocketStates[identifier]

    if updated == nil {
      var session = NetworkInspectorWebSocket(serverID: serverID, socketID: record.id, timestamp: timestamp)
      session.closed = record
      updated = session
      webSocketOrder.append(identifier)
    } else {
      updated?.closed = record
    }

    updated?.lastUpdatedAt = timestamp

    if let updated {
      webSocketStates[identifier] = updated
      return true
    }
    return false
  }

  private func updateWebSocket(
    for serverID: SnapOLinkServerID,
    with record: SnapONetWebSocketFailedRecord
  ) -> Bool {
    let timestamp = Date()
    let identifier = NetworkInspectorWebSocketID(serverID: serverID, socketID: record.id)
    var updated = webSocketStates[identifier]

    if updated == nil {
      var session = NetworkInspectorWebSocket(serverID: serverID, socketID: record.id, timestamp: timestamp)
      session.failed = record
      updated = session
      webSocketOrder.append(identifier)
    } else {
      updated?.failed = record
    }

    updated?.lastUpdatedAt = timestamp

    if let updated {
      webSocketStates[identifier] = updated
      return true
    }
    return false
  }

  private func updateWebSocket(
    for serverID: SnapOLinkServerID,
    with record: SnapONetWebSocketCloseRequestedRecord
  ) -> Bool {
    let timestamp = Date()
    let identifier = NetworkInspectorWebSocketID(serverID: serverID, socketID: record.id)
    var updated = webSocketStates[identifier]

    if updated == nil {
      var session = NetworkInspectorWebSocket(serverID: serverID, socketID: record.id, timestamp: timestamp)
      session.closeRequested = record
      updated = session
      webSocketOrder.append(identifier)
    } else {
      updated?.closeRequested = record
    }

    updated?.lastUpdatedAt = timestamp

    if let updated {
      webSocketStates[identifier] = updated
      return true
    }
    return false
  }

  private func updateWebSocket(
    for serverID: SnapOLinkServerID,
    with record: SnapONetWebSocketCancelledRecord
  ) -> Bool {
    let timestamp = Date()
    let identifier = NetworkInspectorWebSocketID(serverID: serverID, socketID: record.id)
    var updated = webSocketStates[identifier]

    if updated == nil {
      var session = NetworkInspectorWebSocket(serverID: serverID, socketID: record.id, timestamp: timestamp)
      session.cancelled = record
      updated = session
      webSocketOrder.append(identifier)
    } else {
      updated?.cancelled = record
    }

    updated?.lastUpdatedAt = timestamp

    if let updated {
      webSocketStates[identifier] = updated
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

  func clearCompletedEntries() {
    requestStates = requestStates.filter { _, request in
      if request.failure != nil { return false }
      if request.streamClosed != nil {
        return false
      }
      if !request.streamEvents.isEmpty {
        return true
      }
      if request.isLikelyStreamingResponse {
        return true
      }
      return request.response == nil
    }
    requestOrder = requestOrder.filter { requestStates[$0] != nil }

    webSocketStates = webSocketStates.filter { _, session in
      !isComplete(session)
    }
    webSocketOrder = webSocketOrder.filter { webSocketStates[$0] != nil }

    broadcastRequests()
    broadcastWebSockets()
  }

  private func isComplete(_ session: NetworkInspectorWebSocket) -> Bool {
    if session.failed != nil { return true }
    if session.cancelled != nil { return true }
    if session.closed != nil { return true }
    if session.closing != nil { return true }
    return false
  }
}

private extension NetworkInspectorService {
  static func schemaVersionIsNewerThanSupported(_ version: Int) -> Bool {
    version > supportedSchemaVersion
  }
}
