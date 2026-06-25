import Foundation
import Observation
import SnapODeviceClient

@Observable
@MainActor
final class LivePreviewMode {
  private let livePreviewService: LivePreviewService
  private let adbService: ADBService
  private let options: LivePreviewOptions
  private let mediaDisplayMode: MediaDisplayMode
  private let preferredDeviceIDProvider: @MainActor () -> String?
  private let onMediaApplied: @MainActor () -> Void
  private let errorHandler: @MainActor (Error) -> Void
  private var manager: LivePreviewManager?
  @ObservationIgnored private var stopTask: Task<Void, Never>?
  private(set) var isStopping: Bool = false

  init(
    livePreviewService: LivePreviewService,
    adbService: ADBService,
    options: LivePreviewOptions,
    mediaDisplayMode: MediaDisplayMode,
    preferredDeviceIDProvider: @escaping @MainActor () -> String?,
    onMediaApplied: @escaping @MainActor () -> Void,
    errorHandler: @escaping @MainActor (Error) -> Void
  ) {
    self.livePreviewService = livePreviewService
    self.adbService = adbService
    self.options = options
    self.mediaDisplayMode = mediaDisplayMode
    self.preferredDeviceIDProvider = preferredDeviceIDProvider
    self.onMediaApplied = onMediaApplied
    self.errorHandler = errorHandler
  }

  func start(with devices: [Device]) async {
    guard !isStopping else { return }
    let manager = LivePreviewManager(
      livePreviewService: livePreviewService,
      adbService: adbService,
      options: options
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

  func stop() async {
    if let stopTask {
      await stopTask.value
      return
    }

    isStopping = true
    let activeManager = manager
    manager = nil
    let task = Task {
      if let activeManager {
        await activeManager.stop()
      }
    }
    stopTask = task
    await task.value
  }
}

enum LivePreviewModeError: Error {
  case inactive
}
