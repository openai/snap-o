import Foundation
import SnapODeviceClient

/// Starts the preferred capture early and hands it to at most one window.
@MainActor
final class StartupCapturePreparation {
  private enum Preparation {
    case screenshots(deviceIDs: [String], task: Task<ScreenshotCaptureResult, Never>)
    case livePreview(PreparedLivePreview)
  }

  private let screenshots: ScreenshotService
  private let livePreview: LivePreviewService
  private var preparation: Preparation?
  private var cleanupTask: Task<Void, Never>?
  private(set) var isAvailable = true

  init(screenshots: ScreenshotService, livePreview: LivePreviewService) {
    self.screenshots = screenshots
    self.livePreview = livePreview
  }

  func prepare(mode: StartupCaptureMode, devices: [Device], liveOptions: LivePreviewOptions) {
    guard isAvailable else { return }
    guard let firstDevice = devices.first else {
      discardCurrentPreparation()
      return
    }

    switch (mode, preparation) {
    case (.screenshot, .screenshots(let deviceIDs, _)) where deviceIDs == devices.map(\.id):
      return
    case (.livePreview, .livePreview(let prepared))
      where prepared.deviceID == firstDevice.id && prepared.options == liveOptions && prepared.isAvailable:
      return
    default:
      break
    }

    discardCurrentPreparation()
    let cleanup = cleanupTask
    switch mode {
    case .screenshot:
      Perf.step(.appFirstSnapshot, "preload screenshot")
      let screenshots = screenshots
      let task = Task {
        await cleanup?.value
        guard !Task.isCancelled else { return ScreenshotCaptureResult(media: [], failures: []) }
        return await screenshots.capture(for: devices)
      }
      preparation = .screenshots(deviceIDs: devices.map(\.id), task: task)

    case .livePreview:
      Perf.step(.appFirstSnapshot, "preload live preview")
      let livePreview = livePreview
      let deviceID = firstDevice.id
      let task = Task<LivePreviewOperationHandle?, Never> {
        await cleanup?.value
        guard !Task.isCancelled else { return nil }
        do {
          return try await livePreview.start(for: deviceID, options: liveOptions)
        } catch {
          if !(error is CancellationError) {
            SnapOLog.ui.error("Live preview warmup failed: \(error.localizedDescription, privacy: .public)")
          }
          return nil
        }
      }
      preparation = .livePreview(PreparedLivePreview(
        deviceID: deviceID,
        options: liveOptions,
        operationTask: task,
        service: livePreview
      ))
    }
  }

  func claimScreenshots(for devices: [Device]) -> Task<ScreenshotCaptureResult, Never>? {
    guard isAvailable else { return nil }
    prepare(mode: .screenshot, devices: devices, liveOptions: LivePreviewOptions(showsTouches: false))
    isAvailable = false
    guard case .screenshots(_, let task) = preparation else { return nil }
    preparation = nil
    Perf.step(.appFirstSnapshot, "claim preloaded screenshot")
    return task
  }

  func claimLivePreview(for device: Device, options: LivePreviewOptions) -> PreparedLivePreview? {
    guard isAvailable else { return nil }
    prepare(mode: .livePreview, devices: [device], liveOptions: options)
    isAvailable = false
    guard case .livePreview(let prepared) = preparation else { return nil }
    preparation = nil
    Perf.step(.appFirstSnapshot, "claim preloaded live preview")
    return prepared
  }

  func discard() async {
    isAvailable = false
    discardCurrentPreparation()
    await cleanupTask?.value
  }

  private func discardCurrentPreparation() {
    guard let preparation else { return }
    self.preparation = nil
    let previousCleanup = cleanupTask
    switch preparation {
    case .screenshots(_, let task):
      task.cancel()
      cleanupTask = Task {
        await previousCleanup?.value
        _ = await task.value
      }
    case .livePreview(let prepared):
      cleanupTask = Task {
        await previousCleanup?.value
        await prepared.discard()
      }
    }
  }
}
