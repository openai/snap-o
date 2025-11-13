import Foundation
import OSLog

actor LogCatService {
  private struct DeviceState {
    var streamTask: Task<Void, Never>?
    var continuations: [UUID: AsyncStream<LogCatEvent>.Continuation] = [:]
    var events: [LogCatEvent] = []
    var reconnectAttempt: Int = 0
  }

  private let adbService: ADBService
  private let deviceTracker: DeviceTracker
  private let logger = SnapOLog.logCat

  private var isStarted = false
  private var devices: [String: Device] = [:]
  private var deviceStreamTask: Task<Void, Never>?
  private var deviceStates: [String: DeviceState] = [:]

  private static let maxRetainedEvents = 2000
  private static let reconnectBackoffCap: TimeInterval = 5.0

  init(adbService: ADBService, deviceTracker: DeviceTracker) {
    self.adbService = adbService
    self.deviceTracker = deviceTracker
  }

  deinit {
    deviceStreamTask?.cancel()
    for (deviceID, state) in deviceStates {
      state.streamTask?.cancel()
      logger.debug("Deinitializing LogCatService cancelled stream for \(deviceID, privacy: .public)")
    }
  }

  /// Starts device tracking and primes per-device logcat loops as devices appear.
  /// Call once during application setup; subsequent calls are ignored while running.
  func start() async {
    guard !isStarted else { return }
    isStarted = true

    await updateDevices(deviceTracker.latestDevices)

    deviceStreamTask = Task.detached(priority: .utility) { [deviceTracker] in
      let stream = deviceTracker.deviceStream()
      for await snapshot in stream {
        await self.updateDevices(snapshot)
      }
    }
  }

  /// Creates an `AsyncStream` that replays cached events and streams live updates for the device.
  /// The consumer drives iteration while the actor produces events.
  func eventsStream(for deviceID: String) -> AsyncStream<LogCatEvent> {
    let subscriberID = UUID()

    return AsyncStream { continuation in
      Task {
        await self.registerContinuation(
          id: subscriberID,
          deviceID: deviceID,
          continuation: continuation
        )
      }
    }
  }

  /// Removes any buffered events for the device without stopping an active stream.
  func clearHistory(for deviceID: String) {
    guard var state = deviceStates[deviceID] else { return }
    state.events.removeAll(keepingCapacity: false)
    deviceStates[deviceID] = state
  }

  /// Cancels the logcat loop for the device and emits terminal status events describing the stop.
  func stopStreaming(for deviceID: String, reason: String? = nil) async {
    guard var state = deviceStates[deviceID] else { return }
    let wasRunning = state.streamTask != nil
    state.streamTask?.cancel()
    state.streamTask = nil
    deviceStates[deviceID] = state

    if let reason {
      appendEvent(.stream(.disconnected(reason: reason)), to: deviceID)
    }

    if wasRunning {
      appendEvent(.stream(.stopped), to: deviceID)
    }
  }

  // MARK: - Device Tracking

  /// Reconciles managed device streams against the current tracker snapshot.
  /// Starts new streams for arrivals and tears down streams for removals.
  private func updateDevices(_ devices: [Device]) async {
    let activeIDs = Set(devices.map(\.id))
    let knownIDs = Set(self.devices.keys)

    self.devices = Dictionary(uniqueKeysWithValues: devices.map { ($0.id, $0) })

    for id in activeIDs where !knownIDs.contains(id) {
      ensureDeviceState(for: id)
    }

    for id in activeIDs {
      resumeStreamingIfNeeded(for: id)
    }

    for id in knownIDs where !activeIDs.contains(id) {
      await stopStreaming(for: id, reason: "Device removed")
      deviceStates.removeValue(forKey: id)
    }
  }

  /// Lazily creates a `DeviceState` container for the identifier if needed.
  private func ensureDeviceState(for deviceID: String) {
    if deviceStates[deviceID] == nil {
      deviceStates[deviceID] = DeviceState()
    }
  }

  /// Starts a log stream only if listeners are waiting for the device.
  private func resumeStreamingIfNeeded(for deviceID: String) {
    guard let state = deviceStates[deviceID], !state.continuations.isEmpty else { return }
    startStreaming(for: deviceID)
  }

  /// Spawns a detached logcat loop for the device when one is not already running.
  /// No-op if the device is unknown or already has an active task.
  private func startStreaming(for deviceID: String) {
    guard devices[deviceID] != nil else {
      logger.debug("Skipping logcat stream start for unknown device \(deviceID, privacy: .public)")
      return
    }

    ensureDeviceState(for: deviceID)
    guard var state = deviceStates[deviceID] else { return }
    guard state.streamTask == nil else { return }

    logger.debug("Starting logcat stream for \(deviceID, privacy: .public)")

    state.streamTask = Task.detached(priority: .userInitiated) { [weak self] in
      await self?.runStream(for: deviceID)
    }
    deviceStates[deviceID] = state
  }

  /// Adds a subscriber, replays cached events, wires termination cleanup, and ensures streaming is active.
  private func registerContinuation(
    id: UUID,
    deviceID: String,
    continuation: AsyncStream<LogCatEvent>.Continuation
  ) async {
    ensureDeviceState(for: deviceID)
    guard var state = deviceStates[deviceID] else { return }
    state.continuations[id] = continuation
    let history = state.events
    deviceStates[deviceID] = state

    continuation.onTermination = { [weak self] _ in
      Task { await self?.removeContinuation(id: id, deviceID: deviceID) }
    }

    for event in history {
      continuation.yield(event)
    }

    startStreaming(for: deviceID)
  }

  /// Drops the subscriber continuation when its stream terminates.
  private func removeContinuation(id: UUID, deviceID: String) async {
    guard var state = deviceStates[deviceID] else { return }
    state.continuations.removeValue(forKey: id)
    let shouldStop = state.continuations.isEmpty
    deviceStates[deviceID] = state

    if shouldStop {
      await stopStreaming(for: deviceID)
    }
  }

  // MARK: - Streaming

  /// Detached logcat reader that reconnects with exponential backoff until cancelled by the actor.
  private func runStream(for deviceID: String) async {
    defer { Task { await self.streamTaskDidFinish(for: deviceID) } }

    var lastErrorReason: String?

    while !Task.isCancelled {
      if let reason = lastErrorReason {
        let attempt = await recordReconnectAttempt(for: deviceID, reason: reason)
        let delay = min(Self.reconnectBackoffCap, pow(1.5, Double(max(0, attempt - 1))))
        do {
          try await Task.sleep(for: .seconds(delay))
        } catch {
          break
        }
      }

      do {
        let exec = await adbService.exec()
        let socket = try await exec.makeConnection()
        defer { socket.close() }

        try socket.sendTransport(to: deviceID)
        try socket.sendShell("logcat -T 1")

        await recordConnect(for: deviceID)
        lastErrorReason = nil

        var buffer = Data(capacity: 8192)

        while !Task.isCancelled {
          try Task.checkCancellation()

          guard let chunk = try socket.readChunk(maxLength: 4096) else {
            throw ADBError.serverUnavailable("logcat stream ended")
          }

          guard !chunk.isEmpty else { continue }
          buffer.append(chunk)

          while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let lineData = buffer.prefix(upTo: newline).trimTrailingCarriageReturn()
            buffer.removeSubrange(buffer.startIndex ... newline)

            guard !lineData.isEmpty else { continue }
            if let line = String(data: lineData, encoding: .utf8) {
              let entry = LogCatLineParser.parseThreadtime(line)
              await recordEntry(entry, for: deviceID)
            }
          }
        }

        await recordStop(for: deviceID)
        break
      } catch is CancellationError {
        await recordStop(for: deviceID)
        break
      } catch {
        if Task.isCancelled { break }
        lastErrorReason = error.localizedDescription
        logger.error(
          "LogCat ADB stream error for \(deviceID, privacy: .public): \(lastErrorReason ?? "unknown", privacy: .public)"
        )
        await recordDisconnect(for: deviceID, reason: lastErrorReason)
      }
    }
  }

  /// Resets bookkeeping once the detached stream exits.
  private func streamTaskDidFinish(for deviceID: String) async {
    guard var state = deviceStates[deviceID] else { return }
    state.streamTask = nil
    deviceStates[deviceID] = state
  }

  /// Wraps a parsed log entry as an event and enqueues it for subscribers.
  private func recordEntry(_ entry: LogCatEntry, for deviceID: String) async {
    appendEvent(.entry(entry), to: deviceID)
  }

  /// Announces a successful connection and resets the reconnect attempt counter.
  private func recordConnect(for deviceID: String) async {
    resetReconnectAttempt(for: deviceID)
    appendEvent(.stream(.connected), to: deviceID)
  }

  /// Emits a disconnection status message so UIs can surface the reason to users.
  private func recordDisconnect(for deviceID: String, reason: String?) async {
    appendEvent(.stream(.disconnected(reason: reason)), to: deviceID)
  }

  /// Increments the reconnect attempt counter, emits a status event, and returns the attempt number.
  private func recordReconnectAttempt(for deviceID: String, reason: String?) async -> Int {
    guard var state = deviceStates[deviceID] else { return 1 }
    state.reconnectAttempt += 1
    let attempt = state.reconnectAttempt
    deviceStates[deviceID] = state
    appendEvent(.stream(.reconnecting(attempt: attempt, reason: reason)), to: deviceID)
    return attempt
  }

  /// Emits a stopped status event when the streaming loop exits cleanly or is cancelled.
  private func recordStop(for deviceID: String) async {
    appendEvent(.stream(.stopped), to: deviceID)
  }

  /// Clears the reconnect attempt counter after a successful connection.
  private func resetReconnectAttempt(for deviceID: String) {
    guard var state = deviceStates[deviceID] else { return }
    state.reconnectAttempt = 0
    deviceStates[deviceID] = state
  }

  /// Appends an event to the device's buffer (trimming to capacity) and broadcasts it to subscribers.
  private func appendEvent(_ event: LogCatEvent, to deviceID: String) {
    guard var state = deviceStates[deviceID] else { return }

    state.events.append(event)
    if state.events.count > Self.maxRetainedEvents {
      let overflow = state.events.count - Self.maxRetainedEvents
      state.events.removeFirst(overflow)
    }

    let continuations = Array(state.continuations.values)
    deviceStates[deviceID] = state

    for continuation in continuations {
      continuation.yield(event)
    }
  }
}
