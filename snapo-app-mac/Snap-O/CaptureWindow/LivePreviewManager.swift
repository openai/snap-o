import CoreGraphics
import Foundation

@MainActor
final class LivePreviewManager {
  private enum LivePreviewError: Error {
    case unknownDevice
  }

  private let services: AppServices
  private let mediaDidChange: @MainActor ([CaptureMedia]) -> Void
  private let pointerInjector: LivePreviewPointerInjector

  private var deviceOrder: [String] = []
  private var deviceInfo: [String: Device] = [:]
  private var mediaByDeviceID: [String: CaptureMedia] = [:]
  private var captureIDs: [String: UUID] = [:]
  private var lastDisplayInfo: [String: DisplayInfo] = [:]

  init(
    services: AppServices,
    mediaDidChange: @escaping @MainActor ([CaptureMedia]) -> Void
  ) {
    self.services = services
    self.mediaDidChange = mediaDidChange
    pointerInjector = LivePreviewPointerInjector(adb: services.adbService)
  }

  func start(with devices: [Device]) async {
    updateDeviceOrder(with: devices)
    await syncDevices(with: devices, requireRefresh: true)
  }

  func updateDevices(_ devices: [Device]) async {
    updateDeviceOrder(with: devices)
    await syncDevices(with: devices, requireRefresh: false)
  }

  func makeRenderer(for deviceID: String) async throws -> LivePreviewRenderer {
    guard let device = deviceInfo[deviceID] else {
      throw LivePreviewError.unknownDevice
    }

    if lastDisplayInfo[deviceID] == nil {
      let fetched = await fetchDisplayInfos(for: [device])
      if let info = fetched[deviceID] {
        lastDisplayInfo[deviceID] = info
        rebuildMedia()
      }
    }

    let session = try await services.captureService.startLivePreview(for: deviceID)
    let renderer = LivePreviewRenderer(
      session: session,
      deviceID: deviceID
    ) { [weak self] action, source, location in
      Task { await self?.sendPointerEvent(deviceID: deviceID, action: action, source: source, location: location) }
    }

    Task.detached(priority: .userInitiated) { [weak self] in
      guard let self else { return }
      do {
        let media = try await session.waitUntilReady()
        await MainActor.run {
          if let latestDevice = self.deviceInfo[deviceID] {
            self.storeMedia(media, for: latestDevice)
          }
        }
      } catch {
        if error is CancellationError { return }
        await MainActor.run {
          SnapOLog.ui.error(
            "Live preview failed for \(deviceID, privacy: .private): \(error.localizedDescription, privacy: .public)"
          )
        }
      }
    }

    return renderer
  }

  func stopRenderer(_ renderer: LivePreviewRenderer) async {
    _ = await services.captureService.stopLivePreview(session: renderer.session)
  }

  func stop() {
    mediaByDeviceID.removeAll()
    captureIDs.removeAll()
    lastDisplayInfo.removeAll()
    notifyMediaChanged()
  }

  // MARK: - Device + Media Management

  private func syncDevices(with devices: [Device], requireRefresh: Bool) async {
    let currentIDs = Set(devices.map(\.id))

    for id in Array(deviceInfo.keys) where !currentIDs.contains(id) {
      deviceInfo.removeValue(forKey: id)
    }
    for id in Array(lastDisplayInfo.keys) where !currentIDs.contains(id) {
      lastDisplayInfo.removeValue(forKey: id)
    }
    for id in Array(captureIDs.keys) where !currentIDs.contains(id) {
      captureIDs.removeValue(forKey: id)
    }

    for device in devices {
      deviceInfo[device.id] = device
    }

    let devicesToFetch: [Device] = if requireRefresh {
      devices
    } else {
      devices.filter { lastDisplayInfo[$0.id] == nil }
    }

    if !devicesToFetch.isEmpty {
      let fetched = await fetchDisplayInfos(for: devicesToFetch)
      for (id, info) in fetched {
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

    let appServices = services

    return await withTaskGroup(of: (String, DisplayInfo)?.self, returning: [String: DisplayInfo].self) { group in
      for device in devices {
        group.addTask {
          do {
            let exec = await appServices.adbService.exec()
            async let densityTask = try? await exec.displayDensity(deviceID: device.id)
            let sizeString = try await exec.displaySize(deviceID: device.id)
            guard let size = parseDisplaySize(sizeString) else { return nil }
            let density = await densityTask
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
    location: CGPoint
  ) async {
    let event = LivePreviewPointerEvent(
      deviceID: deviceID,
      action: action,
      source: source,
      location: location
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
