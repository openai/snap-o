import CoreGraphics
import Foundation

@MainActor
final class LivePreviewManager {

  private let services: AppServices
  private let mediaDidChange: @MainActor ([CaptureMedia]) -> Void
  private let pointerInjector: LivePreviewPointerInjector

  private var deviceOrder: [String] = []
  private var deviceInfo: [String: Device] = [:]
  private var sessions: [String: LivePreviewSession] = [:]
  private var mediaByDeviceID: [String: CaptureMedia] = [:]
  private var captureIDs: [String: UUID] = [:]
  private var startTasks: [String: Task<Void, Never>] = [:]

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
    await updateDevices(devices)
  }

  func updateDevices(_ devices: [Device]) async {
    updateDeviceOrder(with: devices)
    let currentIDs = Set(devices.map { $0.id })

    for device in devices {
      deviceInfo[device.id] = device
    }

    for id in sessions.keys where !currentIDs.contains(id) {
      stopSession(for: id)
    }

    for device in devices {
      await ensureSession(for: device)
    }

    notifyMediaChanged()
  }

  func stop() {
    for task in startTasks.values { task.cancel() }
    startTasks.removeAll()

    for (id, session) in sessions {
      session.cancel()
      Task { await session.waitUntilStop() }
      mediaByDeviceID.removeValue(forKey: id)
    }
    sessions.removeAll()
    notifyMediaChanged()
  }

  func renderer(for deviceID: String, size: CGSize) -> LivePreviewRenderer? {
    guard let session = sessions[deviceID] else { return nil }
    return LivePreviewRenderer(
      session: session,
      deviceID: deviceID,
      size: size,
      sendPointer: { [weak self] action, source, location in
        Task { await self?.sendPointerEvent(deviceID: deviceID, action: action, source: source, location: location) }
      }
    )
  }

  private func ensureSession(for device: Device) async {
    guard sessions[device.id] == nil, startTasks[device.id] == nil else { return }

    let deviceID = device.id
    let task = Task.detached(priority: .userInitiated) { [weak self] in
      guard let self else { return }
      defer {
        Task { @MainActor in self.startTasks[deviceID] = nil }
      }

      do {
        let session = try await self.services.captureService.startLivePreview(for: deviceID)
        await MainActor.run {
          self.sessions[deviceID] = session
          if self.captureIDs[deviceID] == nil {
            self.captureIDs[deviceID] = UUID()
          }
        }

        let media = try await session.waitUntilReady()
        await MainActor.run {
          if let latestDevice = self.deviceInfo[deviceID] {
            self.storeMedia(media, for: latestDevice)
          }
        }
      } catch {
        await MainActor.run {
          SnapOLog.ui.error("Live preview failed for \(deviceID, privacy: .private): \(error.localizedDescription, privacy: .public)")
        }
      }
    }

    startTasks[device.id] = task
  }

  private func stopSession(for deviceID: String) {
    startTasks[deviceID]?.cancel()
    startTasks[deviceID] = nil

    if let session = sessions.removeValue(forKey: deviceID) {
      session.cancel()
      Task { await session.waitUntilStop() }
    }
    mediaByDeviceID.removeValue(forKey: deviceID)
  }

  private func storeMedia(_ media: Media, for device: Device) {
    let id = captureIDs[device.id] ?? UUID()
    captureIDs[device.id] = id
    mediaByDeviceID[device.id] = CaptureMedia(
      id: id,
      deviceID: device.id,
      device: device,
      media: media
    )
    notifyMediaChanged()
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
