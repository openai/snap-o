import CoreGraphics
import Foundation
import SnapODeviceClient

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

  private var deviceOrder: [String] = []
  private var deviceInfo: [String: Device] = [:]
  private var mediaByDeviceID: [String: CaptureMedia] = [:]
  private var captureIDs: [String: UUID] = [:]
  private var lastDisplayInfo: [String: DisplayInfo] = [:]
  private var activeOperations: [UUID: LivePreviewOperationHandle] = [:]
  private var inFlightRendererRequestIDs: Set<UUID> = []
  private var stoppingRendererIDs: Set<UUID> = []
  private var deviceSyncID = UUID()
  private var isStopped = false

  init(
    livePreviewService: LivePreviewService,
    adbService: ADBService,
    options: LivePreviewOptions,
    preparedLivePreview: PreparedLivePreview? = nil,
    mediaDidChange: @escaping @MainActor ([CaptureMedia]) -> Void
  ) {
    self.livePreviewService = livePreviewService
    self.adbService = adbService
    self.options = options
    self.preparedLivePreview = preparedLivePreview
    self.mediaDidChange = mediaDidChange
    pointerInjector = LivePreviewPointerInjector(adb: adbService)
  }

  func start(with devices: [Device]) async {
    guard !isStopped else { return }
    updateDeviceOrder(with: devices)
    for device in devices {
      deviceInfo[device.id] = device
    }
    if let prepared = preparedLivePreview {
      preparedMediaTask = Task { [weak self] in
        guard let media = await prepared.waitUntilReady(),
              !Task.isCancelled,
              let self,
              !self.isStopped,
              let device = deviceInfo[prepared.deviceID]
        else { return }
        Perf.step(.appFirstSnapshot, "preloaded live preview ready")
        storeMedia(media, for: device)
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
    guard !isStopped else { throw CancellationError() }
    let requestID = UUID()
    inFlightRendererRequestIDs.insert(requestID)
    defer { inFlightRendererRequestIDs.remove(requestID) }

    guard let device = deviceInfo[deviceID] else {
      throw LivePreviewError.unknownDevice
    }

    if lastDisplayInfo[deviceID] == nil {
      let fetched = await fetchDisplayInfos(for: [device])
      guard !isStopped,
            !Task.isCancelled,
            deviceInfo[deviceID] != nil
      else { throw CancellationError() }
      if let info = fetched[deviceID] {
        lastDisplayInfo[deviceID] = info
        rebuildMedia()
      }
    }

    let operation = try await takeOrStartOperation(for: deviceID)
    guard !isStopped,
          !Task.isCancelled,
          deviceInfo[deviceID] != nil
    else {
      _ = await livePreviewService.stop(operation)
      throw CancellationError()
    }
    activeOperations[operation.id] = operation
    await pointerInjector.prepare(deviceID: deviceID)

    let renderer = LivePreviewRenderer(
      operation: operation
    ) { [weak self] action, source, location, displaySize in
      Task {
        await self?.sendPointerEvent(
          deviceID: deviceID,
          action: action,
          source: source,
          location: location,
          displaySize: displaySize
        )
      }
    }

    let session = operation.session
    Task { [weak self] in
      do {
        let media = try await session.waitUntilReady()
        guard let self,
              !isStopped,
              activeOperations[operation.id] != nil,
              let device = deviceInfo[deviceID]
        else { return }
        storeMedia(media, for: device)
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

  private func takeOrStartOperation(for deviceID: String) async throws -> LivePreviewOperationHandle {
    if let prepared = preparedLivePreview {
      preparedLivePreview = nil
      if prepared.deviceID == deviceID, prepared.options == options {
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
    guard activeOperations.removeValue(forKey: operationID) != nil else { return }
    stoppingRendererIDs.insert(operationID)
    defer { stoppingRendererIDs.remove(operationID) }
    _ = await livePreviewService.stop(renderer.operation)
    if !activeOperations.values.contains(where: { $0.deviceID == renderer.deviceID }) {
      await pointerInjector.stopDevice(renderer.deviceID)
    }
  }

  func stop() async {
    guard !isStopped else { return }
    isStopped = true
    preparedMediaTask?.cancel()
    preparedMediaTask = nil
    let prepared = preparedLivePreview
    preparedLivePreview = nil
    let operations = Array(activeOperations.values)
    activeOperations.removeAll()
    mediaByDeviceID.removeAll()
    captureIDs.removeAll()
    lastDisplayInfo.removeAll()
    notifyMediaChanged()
    await prepared?.discard()
    await pointerInjector.stopAll()

    for operation in operations {
      _ = await livePreviewService.stop(operation)
    }
    while !inFlightRendererRequestIDs.isEmpty || !stoppingRendererIDs.isEmpty {
      await Task.yield()
    }
  }

  // MARK: - Device + Media Management

  private func syncDevices(with devices: [Device]) async {
    let syncID = UUID()
    deviceSyncID = syncID
    let currentIDs = Set(devices.map(\.id))
    let removedDeviceIDs = Set(deviceInfo.keys).subtracting(currentIDs)
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

    if let prepared = preparedLivePreview, !currentIDs.contains(prepared.deviceID) {
      preparedLivePreview = nil
      let cleanupID = UUID()
      stoppingRendererIDs.insert(cleanupID)
      await prepared.discard()
      stoppingRendererIDs.remove(cleanupID)
    }
    for operation in removedOperations {
      _ = await livePreviewService.stop(operation)
      stoppingRendererIDs.remove(operation.id)
    }
    for deviceID in removedDeviceIDs {
      await pointerInjector.stopDevice(deviceID)
    }

    guard !isStopped, deviceSyncID == syncID else { return }

    let devicesToFetch = devices.filter { lastDisplayInfo[$0.id] == nil }

    if !devicesToFetch.isEmpty {
      let fetched = await fetchDisplayInfos(for: devicesToFetch)
      guard !isStopped, deviceSyncID == syncID else { return }
      for (id, info) in fetched where deviceInfo[id] != nil && lastDisplayInfo[id] == nil {
        lastDisplayInfo[id] = info
      }
    }

    rebuildMedia()
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

    let adbService = adbService

    return await withTaskGroup(of: (String, DisplayInfo)?.self, returning: [String: DisplayInfo].self) { group in
      for device in devices {
        group.addTask {
          do {
            let exec = await adbService.exec()
            async let densityTask = try? await exec.displayDensity(deviceID: device.id)
            let sizeString = try await exec.displaySize(deviceID: device.id)
            guard let size = parseDisplaySize(sizeString) else { return nil }
            let densityValue = await densityTask
            let density = densityValue.map { CGFloat($0) }
            return (device.id, DisplayInfo(size: size, densityScale: density))
          } catch {
            await MainActor.run {
              SnapOLog.ui.error(
                "Failed to load display info for \(device.id, privacy: .private): \(error.localizedDescription, privacy: .public)"
              )
            }
            return nil
          }
        }
      }

      var results: [String: DisplayInfo] = [:]
      for await result in group {
        if let (id, info) = result {
          results[id] = info
        }
      }
      return results
    }
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
    deviceID: String,
    action: LivePreviewPointerAction,
    source: LivePreviewPointerSource,
    location: CGPoint,
    displaySize: CGSize
  ) async {
    let event = LivePreviewPointerEvent(
      deviceID: deviceID,
      action: action,
      source: source,
      location: location,
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
