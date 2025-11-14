import Foundation
import Observation

@Observable
@MainActor
final class LivePreviewMode {
  private let captureService: CaptureService
  private let adbService: ADBService
  private let mediaDisplayMode: MediaDisplayMode
  private let preferredDeviceIDProvider: @MainActor () -> String?
  private let onMediaApplied: @MainActor () -> Void
  private let errorHandler: @MainActor (Error) -> Void
  private var manager: LivePreviewManager?
  private(set) var isStopping: Bool = false

  init(
    captureService: CaptureService,
    adbService: ADBService,
    mediaDisplayMode: MediaDisplayMode,
    preferredDeviceIDProvider: @escaping @MainActor () -> String?,
    onMediaApplied: @escaping @MainActor () -> Void,
    errorHandler: @escaping @MainActor (Error) -> Void
  ) {
    self.captureService = captureService
    self.adbService = adbService
    self.mediaDisplayMode = mediaDisplayMode
    self.preferredDeviceIDProvider = preferredDeviceIDProvider
    self.onMediaApplied = onMediaApplied
    self.errorHandler = errorHandler
  }

  func start(with devices: [Device]) async {
    let manager = LivePreviewManager(
      captureService: captureService,
      adbService: adbService
    ) { [weak self] media in
      guard let self else { return }
      let preferredDeviceID = preferredDeviceIDProvider()
      mediaDisplayMode.updateMediaList(
        media,
        preserveDeviceID: preferredDeviceID,
        shouldSort: false
      )
      onMediaApplied()
    }
    self.manager?.stop()
    self.manager = manager
    await manager.start(with: devices)
  }

  func updateDevices(_ devices: [Device]) async {
    await manager?.updateDevices(devices)
  }

  func makeRenderer(for deviceID: String) async throws -> LivePreviewRenderer {
    guard let manager else {
      throw LivePreviewModeError.inactive
    }
    do {
      return try await manager.makeRenderer(for: deviceID)
    } catch {
      errorHandler(error)
      throw error
    }
  }

  func stopRenderer(_ renderer: LivePreviewRenderer) async {
    await manager?.stopRenderer(renderer)
  }

  func stop() {
    isStopping = true
    manager?.stop()
    manager = nil
  }
}

enum LivePreviewModeError: Error {
  case inactive
}
