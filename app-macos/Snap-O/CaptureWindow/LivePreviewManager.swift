import CoreGraphics
import Foundation

@MainActor
final class LivePreviewManager {
  private enum LivePreviewError: Error {
    case unknownDevice
  }

  private let livePreviewService: LivePreviewService
  private let adbService: ADBService
  private let options: LivePreviewOptions
  private let mediaDidChange: @MainActor ([CaptureMedia]) -> Void
  private let pointerInjector: LivePreviewPointerInjector
  private var preparedLivePreview: PreparedLivePreview?
  private var preparedMediaTask: Task<Void, Never>?
  private var displayRetryTask: Task<Void, Never>?
  private let warmupSleep: @Sendable (Duration) async throws -> Void
  private let displayRetrySleep: @Sendable (Duration) async throws -> Void

  private var deviceOrder: [String] = []
  private var deviceInfo: [String: Device] = [:]
  private var mediaByDeviceID: [String: CaptureMedia] = [:]
  private var captureIDs: [String: UUID] = [:]
  private struct DisplayDiscovery {
    let id = UUID()
    let task: Task<DisplayInfo?, Never>
  }

  private var displayDiscoveries: [String: DisplayDiscovery] = [:]
  private var lastDisplayInfo: [String: DisplayInfo] = [:]
  private var activeOperations: [UUID: LivePreviewOperationHandle] = [:]
  private struct EmulatorWarmup {
    let prepared: PreparedLivePreview
    let task: Task<Void, Never>
  }

  private var preparingDeviceID: String?
  private var emulatorWarmups: [String: EmulatorWarmup] = [:]
  private var interactiveOperationIDs: Set<UUID> = []
  private var readinessTasks: [UUID: Task<Void, Never>] = [:]
  private var inFlightRendererRequestIDs: Set<UUID> = []
  private var stoppingRendererIDs: Set<UUID> = []
  private var deviceSyncID = UUID()
  private var isStopped = false

  init(
    livePreviewService: LivePreviewService,
    adbService: ADBService,
    options: LivePreviewOptions,
    preparedLivePreview: PreparedLivePreview? = nil,
    warmupSleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
    displayRetrySleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
    mediaDidChange: @escaping @MainActor ([CaptureMedia]) -> Void
  ) {
    self.livePreviewService = livePreviewService
    self.adbService = adbService
    self.options = options
    self.preparedLivePreview = preparedLivePreview
    self.displayRetrySleep = displayRetrySleep
    self.warmupSleep = warmupSleep
    self.mediaDidChange = mediaDidChange
    pointerInjector = LivePreviewPointerInjector(adb: adbService)
  }

  func start(with devices: [Device]) async {
    guard !isStopped else { return }
    updateDeviceOrder(with: devices)
    for device in devices {
      deviceInfo[device.id] = device
    }
    if let prepared = preparedLivePreview, !EmulatorGRPCEndpoint.isEmulator(prepared.deviceID) {
      preparingDeviceID = prepared.deviceID
      preparedMediaTask = Task { [weak self] in
        let media = await prepared.waitUntilReady()
        guard !Task.isCancelled, let self, !isStopped,
              let device = deviceInfo[prepared.deviceID] else { return }
        preparingDeviceID = nil
        if let media {
          Perf.step(.appFirstSnapshot, "preloaded live preview ready")
          storeMedia(media, for: device)
        } else {
          await syncDevices(with: deviceOrder.compactMap { deviceInfo[$0] })
        }
      }
    }
    await syncDevices(with: devices)
  }

  func updateDevices(_ devices: [Device]) async {
    guard !isStopped else { return }
    updateDeviceOrder(with: devices)
    await syncDevices(with: devices)
  }

  func makeRenderer(for deviceID: String) async throws -> LivePreviewRenderer {
    #if PERF_TRACING
    let timing = Perf.startupBegin("make renderer", deviceID: deviceID)
    defer { Perf.startupEnd(timing) }
    #endif
    guard !isStopped else { throw CancellationError() }
    let requestID = UUID()
    inFlightRendererRequestIDs.insert(requestID)
    defer { inFlightRendererRequestIDs.remove(requestID) }

    guard deviceInfo[deviceID] != nil else { throw LivePreviewError.unknownDevice }

    let operation = try await takeOrStartOperation(for: deviceID)
    guard !isStopped,
          !Task.isCancelled,
          deviceInfo[deviceID] != nil
    else {
      _ = await livePreviewService.stop(operation)
      throw CancellationError()
    }
    activeOperations[operation.id] = operation

    let renderer = LivePreviewRenderer(
      operation: operation
    ) { [weak self] action, source, locations, displaySize in
      Task {
        await self?.sendPointerEvent(
          operation: operation,
          action: action,
          source: source,
          locations: locations,
          displaySize: displaySize
        )
      }
    }

    let session = operation.session
    readinessTasks[operation.id] = Task { [weak self] in
      do {
        _ = try await session.waitUntilReady()
        guard let self,
              !isStopped,
              activeOperations[operation.id] != nil,
              session.isReady,
              let device = deviceInfo[deviceID]
        else { return }
        session.mediaDidChange = { [weak self] media in
          guard let self, !isStopped, activeOperations[operation.id] != nil,
                let device = deviceInfo[deviceID] else { return }
          storeMedia(media, for: device)
        }
        if let media = session.media { storeMedia(media, for: device) }
        guard await livePreviewService.waitUntilInteractive(operation),
              !isStopped, activeOperations[operation.id] != nil, session.isReady else { return }
        await pointerInjector.prepare(deviceID: deviceID)
        guard !isStopped, activeOperations[operation.id] != nil else { return }
        interactiveOperationIDs.insert(operation.id)
      } catch {
        if !(error is CancellationError) {
          SnapOLog.ui.error(
            "Live preview failed for \(deviceID, privacy: .private): \(error.localizedDescription, privacy: .public)"
          )
        }
      }
    }

    return renderer
  }

  private func startEmulatorWarmups(for devices: [Device]) {
    for device in devices where EmulatorGRPCEndpoint.isEmulator(device.id) {
      guard lastDisplayInfo[device.id] == nil, emulatorWarmups[device.id] == nil else { continue }
      let prepared: PreparedLivePreview
      if let existing = preparedLivePreview, existing.deviceID == device.id, existing.options == options {
        preparedLivePreview = nil
        prepared = existing
      } else {
        prepared = PreparedLivePreview(
          deviceID: device.id, options: options,
          operationTask: PreparedLivePreview.startOperation(for: device.id, options: options, service: livePreviewService),
          service: livePreviewService, sleep: warmupSleep
        )
      }
      prepared.expireAfterReadiness()
      let task = Task { [weak self] in
        let media = await prepared.waitUntilReady()
        guard let self, !Task.isCancelled, !isStopped,
              emulatorWarmups[device.id]?.prepared === prepared,
              let currentDevice = deviceInfo[device.id] else { return }
        if let media {
          storeMedia(media, for: currentDevice)
        } else {
          emulatorWarmups.removeValue(forKey: device.id)
          let cleanupID = UUID()
          stoppingRendererIDs.insert(cleanupID)
          await prepared.discard()
          stoppingRendererIDs.remove(cleanupID)
        }
      }
      emulatorWarmups[device.id] = EmulatorWarmup(prepared: prepared, task: task)
    }
  }

  private func takeOrStartOperation(for deviceID: String) async throws -> LivePreviewOperationHandle {
    #if PERF_TRACING
    Perf.startupEvent("take or start operation", deviceID: deviceID)
    #endif
    if let warmup = emulatorWarmups.removeValue(forKey: deviceID) {
      warmup.task.cancel()
      if let operation = await warmup.prepared.take() { return operation }
    }
    if let prepared = preparedLivePreview, prepared.deviceID == deviceID {
      preparedLivePreview = nil
      if prepared.options == options {
        if let operation = await prepared.take() {
          Perf.step(.appFirstSnapshot, "reuse preloaded live preview")
          return operation
        }
      } else {
        await prepared.discard()
      }
    }
    guard !isStopped, !Task.isCancelled, deviceInfo[deviceID] != nil else {
      throw CancellationError()
    }
    return try await livePreviewService.start(for: deviceID, options: options)
  }

  func stopRenderer(_ renderer: LivePreviewRenderer) async {
    let operationID = renderer.operation.id
    guard let operation = activeOperations.removeValue(forKey: operationID) else { return }
    stoppingRendererIDs.insert(operationID)
    defer { stoppingRendererIDs.remove(operationID) }
    await stopOperation(operation)
    if !activeOperations.values.contains(where: { $0.deviceID == renderer.deviceID }) {
      await pointerInjector.stopDevice(renderer.deviceID)
    }
  }

  func stop() async {
    guard !isStopped else { return }
    isStopped = true
    displayRetryTask?.cancel()
    displayRetryTask = nil
    preparedMediaTask?.cancel()
    preparedMediaTask = nil
    let discoveries = Array(displayDiscoveries.values)
    displayDiscoveries.removeAll()
    for discovery in discoveries {
      discovery.task.cancel()
    }
    let prepared = preparedLivePreview
    preparedLivePreview = nil
    let warmups = Array(emulatorWarmups.values)
    emulatorWarmups.removeAll()
    for warmup in warmups {
      warmup.task.cancel()
    }
    let operations = Array(activeOperations.values)
    activeOperations.removeAll()
    mediaByDeviceID.removeAll()
    captureIDs.removeAll()
    lastDisplayInfo.removeAll()
    notifyMediaChanged()
    await prepared?.discard()

    for operation in operations {
      await stopOperation(operation)
    }
    for warmup in warmups {
      await warmup.prepared.discard()
      await warmup.task.value
    }
    while !inFlightRendererRequestIDs.isEmpty || !stoppingRendererIDs.isEmpty {
      await Task.yield()
    }
    await pointerInjector.stopAll()
  }

  private func stopOperation(_ operation: LivePreviewOperationHandle) async {
    interactiveOperationIDs.remove(operation.id)
    let readinessTask = readinessTasks.removeValue(forKey: operation.id)
    // Stopping the session releases readiness waiters before we await queued input setup.
    _ = await livePreviewService.stop(operation)
    await readinessTask?.value
  }

  // MARK: - Device + Media Management

  private func syncDevices(with devices: [Device]) async {
    let syncID = UUID()
    deviceSyncID = syncID
    displayRetryTask?.cancel()
    displayRetryTask = nil
    let currentIDs = Set(devices.map(\.id))
    let removedDeviceIDs = Set(deviceInfo.keys).subtracting(currentIDs)
    if let preparingDeviceID, !currentIDs.contains(preparingDeviceID) {
      self.preparingDeviceID = nil
      preparedMediaTask?.cancel()
      preparedMediaTask = nil
    }
    for id in removedDeviceIDs {
      displayDiscoveries.removeValue(forKey: id)?.task.cancel()
    }
    let removedWarmups = emulatorWarmups.filter { !currentIDs.contains($0.key) }
    let warmupCleanupID = UUID()
    if !removedWarmups.isEmpty { stoppingRendererIDs.insert(warmupCleanupID) }
    defer { stoppingRendererIDs.remove(warmupCleanupID) }
    for (id, warmup) in removedWarmups {
      emulatorWarmups.removeValue(forKey: id)
      warmup.task.cancel()
    }
    let removedOperations = activeOperations.values.filter { !currentIDs.contains($0.deviceID) }
    for operation in removedOperations {
      activeOperations.removeValue(forKey: operation.id)
      stoppingRendererIDs.insert(operation.id)
    }
    deviceInfo = Dictionary(uniqueKeysWithValues: devices.map { ($0.id, $0) })
    for id in Array(lastDisplayInfo.keys) where !currentIDs.contains(id) {
      lastDisplayInfo.removeValue(forKey: id)
    }
    for id in Array(captureIDs.keys) where !currentIDs.contains(id) {
      captureIDs.removeValue(forKey: id)
    }

    // Remove disconnected previews before stream cleanup or new-device discovery can suspend.
    rebuildMedia()

    if let prepared = preparedLivePreview, !currentIDs.contains(prepared.deviceID) {
      preparedLivePreview = nil
      let cleanupID = UUID()
      stoppingRendererIDs.insert(cleanupID)
      await prepared.discard()
      stoppingRendererIDs.remove(cleanupID)
    }
    for operation in removedOperations {
      await stopOperation(operation)
      stoppingRendererIDs.remove(operation.id)
    }
    for deviceID in removedDeviceIDs {
      await pointerInjector.stopDevice(deviceID)
    }

    for warmup in removedWarmups.values {
      await warmup.prepared.discard()
      await warmup.task.value
    }
    guard !isStopped, deviceSyncID == syncID else { return }
    startEmulatorWarmups(for: devices)

    guard await refreshDisplayInfos(for: devices, syncID: syncID) else { return }

    // ADB can connect before Android's display services are ready, without another device update.
    displayRetryTask = Task { [weak self, sleep = displayRetrySleep] in
      var delay = Duration.seconds(1)
      while true {
        do { try await sleep(delay) } catch { return }
        guard await self?.refreshDisplayInfos(for: devices, syncID: syncID) == true else { return }
        delay = min(delay * 2, .seconds(10))
      }
    }
  }

  /// Returns whether this device update still needs another discovery attempt.
  private func refreshDisplayInfos(for devices: [Device], syncID: UUID) async -> Bool {
    guard !Task.isCancelled, !isStopped, deviceSyncID == syncID else { return false }
    #if PERF_TRACING
    Perf.startupEvent("manager display discovery begin")
    #endif
    let missing = devices.filter { lastDisplayInfo[$0.id] == nil && emulatorWarmups[$0.id] == nil && preparingDeviceID != $0.id }
    let fetched = await fetchDisplayInfos(for: missing)
    #if PERF_TRACING
    Perf.startupEvent("manager display discovery end")
    #endif

    guard !Task.isCancelled, !isStopped, deviceSyncID == syncID else { return false }
    for (id, info) in fetched where lastDisplayInfo[id] == nil {
      lastDisplayInfo[id] = info
    }
    rebuildMedia()
    return devices.contains { lastDisplayInfo[$0.id] == nil }
  }

  private func storeMedia(_ media: Media, for device: Device) {
    lastDisplayInfo[device.id] = media.common.display
    rebuildMedia()
  }

  private func rebuildMedia() {
    var changed = false
    let currentIDs = Set(deviceInfo.keys)

    for id in Array(mediaByDeviceID.keys) where !currentIDs.contains(id) {
      mediaByDeviceID.removeValue(forKey: id)
      captureIDs.removeValue(forKey: id)
      changed = true
    }

    for id in deviceOrder {
      guard currentIDs.contains(id),
            let device = deviceInfo[id],
            let display = lastDisplayInfo[id]
      else { continue }

      let captureID = captureID(for: id)
      let updated = makeCapture(for: device, captureID: captureID, display: display)
      if mediaByDeviceID[id] != updated {
        mediaByDeviceID[id] = updated
        changed = true
      }
    }

    if changed {
      notifyMediaChanged()
    }
  }

  private func fetchDisplayInfos(for devices: [Device]) async -> [String: DisplayInfo] {
    guard !devices.isEmpty else { return [:] }

    return await withTaskGroup(of: (String, DisplayInfo?).self) { group in
      for device in devices {
        group.addTask { await (device.id, self.displayInfo(for: device.id)) }
      }
      var results: [String: DisplayInfo] = [:]
      for await (id, info) in group {
        results[id] = info
      }
      return results
    }
  }

  private func displayInfo(for deviceID: String) async -> DisplayInfo? {
    if let info = lastDisplayInfo[deviceID] { return info }
    let discovery: DisplayDiscovery
    if let pending = displayDiscoveries[deviceID] {
      discovery = pending
    } else {
      let task = Task { [adbService] () -> DisplayInfo? in
        do {
          let exec = await adbService.exec()
          guard try await exec.isBootComplete(deviceID: deviceID) else { return nil }
          async let density = exec.displayDensity(deviceID: deviceID)
          let sizeValue = try await exec.displaySize(deviceID: deviceID)
          guard let size = parseDisplaySize(sizeValue) else { return nil }
          return try await DisplayInfo(size: size, densityScale: CGFloat(density))
        } catch { return nil }
      }
      discovery = DisplayDiscovery(task: task)
      displayDiscoveries[deviceID] = discovery
    }
    let info = await discovery.task.value
    if displayDiscoveries[deviceID]?.id == discovery.id {
      displayDiscoveries.removeValue(forKey: deviceID)
      if !isStopped, deviceInfo[deviceID] != nil, lastDisplayInfo[deviceID] == nil {
        lastDisplayInfo[deviceID] = info
      }
    }
    return info
  }

  private func captureID(for deviceID: String) -> UUID {
    if let existing = captureIDs[deviceID] { return existing }
    let id = UUID()
    captureIDs[deviceID] = id
    return id
  }

  private func makeCapture(for device: Device, captureID: UUID, display: DisplayInfo) -> CaptureMedia {
    CaptureMedia(
      id: captureID,
      device: device,
      media: .livePreview(
        capturedAt: Date(),
        display: display
      )
    )
  }

  private func notifyMediaChanged() {
    let media = deviceOrder.compactMap { mediaByDeviceID[$0] }
    mediaDidChange(media)
  }

  private func updateDeviceOrder(with devices: [Device]) {
    for device in devices where !deviceOrder.contains(device.id) {
      deviceOrder.append(device.id)
    }
  }

  private func sendPointerEvent(
    operation: LivePreviewOperationHandle,
    action: LivePreviewPointerAction,
    source: LivePreviewPointerSource,
    locations: [CGPoint],
    displaySize: CGSize
  ) async {
    guard !isStopped,
          activeOperations[operation.id] != nil,
          operation.session.isReady,
          interactiveOperationIDs.contains(operation.id) else { return }
    let event = LivePreviewPointerEvent(
      deviceID: operation.deviceID,
      action: action,
      source: source,
      locations: locations,
      displaySize: displaySize
    )
    await pointerInjector.enqueue(event)
  }
}

private func parseDisplaySize(_ value: String) -> CGSize? {
  let components = value.split(separator: "x")
  guard components.count == 2,
        let width = Double(components[0]),
        let height = Double(components[1]),
        width > 0,
        height > 0
  else {
    return nil
  }
  return CGSize(width: CGFloat(width), height: CGFloat(height))
}
