import Dependencies
import Foundation

private let log = SnapOLog.tracker

actor DeviceTracker {
  private let adbService: ADBService
  private let recoverADBServer: @Sendable () async throws -> Void
  @Dependency(\.continuousClock)
  private var clock
  private var infoCache: [DeviceTarget: DeviceInfo] = [:]

  private(set) var serverState: ADBServerState = .connecting
  private var serverStateContinuations: [UUID: AsyncStream<ADBServerState>.Continuation] = [:]
  private var trackTask: Task<Void, Never>?
  private var propertyTasks: [UUID: Task<Void, Never>] = [:]
  private var recoveryTask: Task<Void, Never>?
  private var stoppingTask: Task<Void, Never>?
  private var continuations: [UUID: AsyncStream<[Device]>.Continuation] = [:]
  private(set) var latestDevices: [Device] = []

  private var previewContinuations: [UUID: AsyncStream<[Device]>.Continuation] = [:]
  private var previewDevices: [Device] = []
  private var targets: [String: DeviceTarget] = [:]

  private func target(for serial: String, transportID: String?, server: (any DeviceServerConnection)?) -> DeviceTarget {
    if let existing = targets[serial], existing.transportID == transportID, existing.server?.id == server?.id, existing.isValid {
      return existing
    }
    if let old = targets.removeValue(forKey: serial) {
      old.invalidate()
      infoCache.removeValue(forKey: old)
    }
    let target = DeviceTarget(serial: serial, transportID: transportID, server: server)
    targets[serial] = target
    return target
  }

  private func retainTargets(_ serials: Set<String>) {
    for serial in Array(targets.keys) where !serials.contains(serial) {
      if let old = targets.removeValue(forKey: serial) {
        old.invalidate()
        infoCache.removeValue(forKey: old)
      }
    }
  }

  private var hasSeenDeviceIDs = false

  /// Preview transport needs a connected serial, not descriptive Android properties.
  func previewDeviceStream() -> AsyncStream<[Device]> {
    let id = UUID()
    return AsyncStream { continuation in
      guard stoppingTask == nil else { continuation.finish(); return }
      previewContinuations[id] = continuation
      if hasSeenDeviceIDs { continuation.yield(previewDevices) }
      continuation.onTermination = { [weak self] _ in
        Task { await self?.removePreviewContinuation(id) }
      }
    }
  }

  private func removePreviewContinuation(_ id: UUID) {
    previewContinuations.removeValue(forKey: id)
  }

  private func broadcastPreview(_ devices: [Device]) {
    previewDevices = devices
    hasSeenDeviceIDs = true
    for continuation in previewContinuations.values {
      continuation.yield(devices)
    }
  }

  private var hasSeenFirstMessage: Bool = false

  init(adbService: ADBService, recoverADBServer: @escaping @Sendable () async throws -> Void = {}) {
    self.adbService = adbService
    self.recoverADBServer = recoverADBServer
  }

  // MARK: - Public API

  func deviceStream() -> AsyncStream<[Device]> {
    let id = UUID()
    return AsyncStream { continuation in
      guard stoppingTask == nil else { continuation.finish(); return }
      continuations[id] = continuation
      if self.hasSeenFirstMessage {
        continuation.yield(self.latestDevices)
      }

      continuation.onTermination = { [weak self] _ in
        Task { await self?.removeContinuation(id) }
      }
    }
  }

  func serverStateStream() -> AsyncStream<ADBServerState> {
    let id = UUID()
    return AsyncStream { continuation in
      guard stoppingTask == nil else { continuation.finish(); return }
      serverStateContinuations[id] = continuation
      continuation.yield(serverState)
      continuation.onTermination = { [weak self] _ in
        Task { await self?.removeServerStateContinuation(id) }
      }
    }
  }

  private func removeServerStateContinuation(_ id: UUID) {
    serverStateContinuations.removeValue(forKey: id)
  }

  private func updateServerState(_ state: ADBServerState) {
    guard serverState != state else { return }
    serverState = state
    for continuation in serverStateContinuations.values {
      continuation.yield(state)
    }
  }

  func retryADBServer() async {
    guard trackTask != nil, !Task.isCancelled, case .unavailable = serverState else { return }
    await attemptRecovery()
  }

  private func attemptRecovery() async {
    guard recoveryTask == nil, stoppingTask == nil else { return }
    updateServerState(.starting)
    let task = Task {
      defer { recoveryTask = nil }
      do {
        try Task.checkCancellation()
        try await recoverADBServer()
        guard !Task.isCancelled, serverState == .starting else { return }
        updateServerState(.connecting)
      } catch {
        guard !Task.isCancelled, serverState == .starting else { return }
        updateServerState(.unavailable(error.localizedDescription))
      }
    }
    recoveryTask = task
    await withTaskCancellationHandler {
      await task.value
    } onCancel: { task.cancel() }
  }

  // MARK: - Tracking

  func startTracking() {
    #if PERF_TRACING
    Perf.startupEvent("tracker start entered")
    #endif
    guard trackTask == nil, stoppingTask == nil, !Task.isCancelled else { return }
    trackTask = Task { [weak self] in
      await self?.trackLoop()
    }
  }

  func stopTracking() async {
    if let stoppingTask {
      await stoppingTask.value
      return
    }
    retainTargets([])
    let pending = [trackTask, recoveryTask].compactMap { $0 } + Array(propertyTasks.values)
    for task in pending { task.cancel() }
    trackTask = nil
    let activeContinuations = Array(continuations.values)
    continuations.removeAll()
    for continuation in activeContinuations { continuation.finish() }
    for continuation in previewContinuations.values { continuation.finish() }
    previewContinuations.removeAll()
    for continuation in serverStateContinuations.values { continuation.finish() }
    serverStateContinuations.removeAll()
    let task = Task {
      for task in pending { await task.value }
    }
    stoppingTask = task
    await task.value
    stoppingTask = nil
  }

  private func cancelPropertyRequests() {
    for task in propertyTasks.values { task.cancel() }
  }

  private func removeContinuation(_ id: UUID) {
    continuations.removeValue(forKey: id)
  }

  private func broadcast(_ devices: [Device]) {
    #if PERF_TRACING
    Perf.startupEvent("device properties published")
    #endif
    let enriched = Dictionary(uniqueKeysWithValues: devices.map { ($0.id, $0) })
    broadcastPreview(previewDevices.map { enriched[$0.id] ?? $0 })
    latestDevices = devices
    hasSeenFirstMessage = true
    let snapshot = Array(continuations.values)
    for continuation in snapshot {
      continuation.yield(devices)
    }
  }

  private func trackLoop() async {
    #if PERF_TRACING
    Perf.startupEvent("tracker loop entered")
    #endif
    @inline(__always)
    func pause() async {
      try? await clock.sleep(for: .milliseconds(300))
    }

    var attemptedRecovery = false
    while !Task.isCancelled {
      let exec = await adbService.exec()
      guard let (handle, stream) = try? await exec.trackDevices() else {
        if Task.isCancelled { break }
        await handleTrackingInterruption()
        if Task.isCancelled { break }
        if !attemptedRecovery {
          attemptedRecovery = true
          await attemptRecovery()
        } else if serverState == .connecting {
          updateServerState(.unavailable("Could not connect to the local ADB server."))
        }
        await pause()
        continue
      }

      defer { handle.cancel() }

      do {
        for try await payload in stream {
          if Task.isCancelled { break }
          attemptedRecovery = false
          updateServerState(.online)
          let devices = payload.split(separator: "\n").compactMap(parseDeviceRow).map { row in
            Device(
              id: row.id,
              model: row.fields["model"] ?? row.id,
              androidVersion: "",
              vendorModel: nil,
              manufacturer: nil,
              avdName: nil,
              transportID: row.fields["transport_id"],
              connection: target(for: row.id, transportID: row.fields["transport_id"], server: handle.server)
            )
          }
          retainTargets(Set(devices.map(\.id)))
          broadcastPreview(devices)
          cancelPropertyRequests()
          let requestID = UUID()
          propertyTasks[requestID] = Task {
            defer { propertyTasks[requestID] = nil }
            await refreshProperties(from: payload, exec: exec)
          }
        }
        if Task.isCancelled { break }
      } catch is CancellationError {
        break
      } catch {
        // Failed reads reconnect through the same path as a closed stream.
      }
      await handleTrackingInterruption()
      await pause()
    }
  }

  private func handleTrackingInterruption() async {
    retainTargets([])
    if serverState == .online { updateServerState(.connecting) }
    cancelPropertyRequests()
    infoCache.removeAll()
    broadcastPreview([])
    if hasSeenFirstMessage { broadcast([]) }
  }

  private func refreshProperties(from payload: String, exec: ADBClient) async {
    #if PERF_TRACING
    let timing = Perf.startupBegin("discovery properties batch")
    defer { Perf.startupEnd(timing) }
    #endif
    let deviceCount = payload.split(separator: "\n").compactMap(parseDeviceRow).count
    while !Task.isCancelled {
      let devices = await parseDevices(from: payload, exec: exec)
      guard !Task.isCancelled else { return }
      broadcast(devices)
      guard devices.count < deviceCount else { return }
      // Successful properties are cached; only failed devices need another shell request.
      do {
        try await clock.sleep(for: .seconds(3))
      } catch {
        return
      }
    }
  }

  // MARK: - Device parsing

  private func parseDevices(from payload: String, exec: ADBClient) async -> [Device] {
    let parsed = payload
      .split(separator: "\n", omittingEmptySubsequences: true)
      .compactMap(parseDeviceRow)

    return await withTaskGroup(of: (Int, Device)?.self) { group in
      for (index, element) in parsed.enumerated() {
        guard let connection = targets[element.id] else { continue }
        group.addTask {
          let (id, fields) = element
          guard let info = await self.deviceInfo(
            for: id,
            connection: connection,
            fallbackModel: fields["model"],
            exec: exec
          ) else { return nil }
          return (
            index,
            Device(
              id: id,
              model: info.model,
              androidVersion: info.version,
              vendorModel: info.vendorModel,
              manufacturer: info.manufacturer,
              avdName: info.avdName,
              transportID: fields["transport_id"],
              connection: connection
            )
          )
        }
      }
      var out: [(Int, Device)] = []
      for await indexedDevice in group {
        if let indexedDevice { out.append(indexedDevice) }
      }
      return out.sorted { $0.0 < $1.0 }.map(\.1)
    }
  }

  /// Parses a single `adb devices -l` row like:
  ///   `<serial> device product:foo model:Pixel_7 device:panther transport_id:3`
  /// Returns nil for headers, empties, or unwanted states (offline/unauthorized).
  private func parseDeviceRow(_ line: Substring) -> (id: String, fields: [String: String])? {
    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    let parts = trimmed.split(whereSeparator: \.isWhitespace)
    guard let first = parts.first else { return nil }
    let id = String(first)

    if parts.count >= 2 {
      let state = parts[1].lowercased()
      if state.contains("offline") || state.contains("unauthorized") || state.contains("recovery") || state.contains("authorizing") || state
        .contains("detached") {
        return nil
      }
    }

    // Parse key:value pairs into a dictionary.
    var fields: [String: String] = [:]
    fields.reserveCapacity(6)
    for part in parts.dropFirst() {
      if let idx = part.firstIndex(of: ":") {
        let key = String(part[..<idx])
        let value = String(part[part.index(after: idx)...])
        fields[key] = value
      }
    }

    return (id, fields)
  }

  private func deviceInfo(
    for id: String,
    connection: DeviceTarget,
    fallbackModel: String?,
    exec: ADBClient
  ) async -> DeviceInfo? {
    guard connection.isValid, targets[id] == connection else { return nil }
    if let cached = infoCache[connection] {
      return cached
    }

    // A failed shell request means this device is not ready for discovery or capture.
    let client = exec.bound(to: connection)
    guard let props = try? await client.getProperties(deviceID: id, prefix: "ro."),
          connection.isValid, targets[id] == connection else { return nil }

    let model = fallbackModel
      ?? cleanProp("ro.product.model", in: props)
      ?? "Unknown Model"
    let version = cleanProp("ro.build.version.release", in: props) ?? "Unknown API"
    let vendorModel = cleanProp("ro.product.vendor.model", in: props)
    let manufacturer = cleanProp("ro.product.vendor.manufacturer", in: props)
      ?? cleanProp("ro.product.manufacturer", in: props)
    let avdName = cleanProp("ro.boot.qemu.avd_name", in: props)
      .map { $0.replacingOccurrences(of: "_", with: " ") }

    let info = DeviceInfo(
      model: model,
      version: version,
      vendorModel: vendorModel,
      manufacturer: manufacturer,
      avdName: avdName
    )
    guard !Task.isCancelled else { return nil }
    infoCache[connection] = info
    return info
  }

  // MARK: - Helpers

  private struct DeviceInfo {
    let model: String
    let version: String
    let vendorModel: String?
    let manufacturer: String?
    let avdName: String?
  }

  // MARK: - Property helpers

  private func cleanProp(_ key: String, in props: [String: String]) -> String? {
    guard let raw = props[key]?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
    return raw.isEmpty ? nil : raw
  }
}
