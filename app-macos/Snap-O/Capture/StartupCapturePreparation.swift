import Foundation

/// Starts the preferred capture early and hands it to at most one window.
@MainActor
final class StartupCapturePreparation {
  private enum Preparation {
    case screenshots(deviceIDs: [String], task: Task<ScreenshotCaptureResult, Never>)
    case livePreview(deviceID: String?, options: LivePreviewOptions, task: Task<PreparedLivePreview?, Never>)
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

  func prepareEarlyPreview(
    options: LivePreviewOptions,
    deviceIDs: @escaping @Sendable () async -> String?
  ) {
    guard isAvailable, preparation == nil else { return }
    preparation = .livePreview(deviceID: nil, options: options, task: previewTask(options: options, resolveDeviceID: deviceIDs))
  }

  func prepare(mode: StartupCaptureMode, devices: [Device], liveOptions: LivePreviewOptions) {
    guard isAvailable else { return }
    switch (mode, preparation) {
    case (.screenshot, .screenshots(let deviceIDs, _)) where deviceIDs == devices.map(\.id):
      return
    case (.livePreview, .livePreview(let deviceID, let options, _))
      where options == liveOptions && (deviceID == nil || deviceID == devices.first?.id):
      return
    default:
      break
    }

    discardCurrentPreparation()
    guard let firstDevice = devices.first else { return }
    switch mode {
    case .screenshot:
      Perf.step(.appFirstSnapshot, "preload screenshot")
      let screenshots = screenshots
      let cleanup = cleanupTask
      let task = Task {
        await cleanup?.value
        guard !Task.isCancelled else { return ScreenshotCaptureResult(media: [], failures: []) }
        return await screenshots.capture(for: devices)
      }
      preparation = .screenshots(deviceIDs: devices.map(\.id), task: task)
    case .livePreview:
      Perf.step(.appFirstSnapshot, "preload live preview")
      preparation = .livePreview(
        deviceID: firstDevice.id,
        options: liveOptions,
        task: previewTask(options: liveOptions) { firstDevice.id }
      )
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

  func claimLivePreview(for device: Device, options: LivePreviewOptions) async -> PreparedLivePreview? {
    guard isAvailable else { return nil }
    prepare(mode: .livePreview, devices: [device], liveOptions: options)
    isAvailable = false
    guard case .livePreview(_, _, let task) = preparation else { return nil }
    preparation = nil
    let prepared = await withTaskCancellationHandler {
      await task.value
    } onCancel: { task.cancel() }
    if let prepared, prepared.deviceID == device.id, prepared.isAvailable, !Task.isCancelled {
      Perf.step(.appFirstSnapshot, "claim preloaded live preview")
      return prepared
    }
    await prepared?.discard()
    guard !Task.isCancelled else { return nil }
    let replacement = previewTask(options: options) { device.id }
    return await withTaskCancellationHandler {
      let prepared = await replacement.value
      guard !Task.isCancelled else {
        await prepared?.discard()
        return nil
      }
      return prepared
    } onCancel: { replacement.cancel() }
  }

  private func previewTask(
    options: LivePreviewOptions,
    resolveDeviceID: @escaping @Sendable () async -> String?
  ) -> Task<PreparedLivePreview?, Never> {
    Task.detached(priority: .userInitiated) { [service = livePreview, cleanup = cleanupTask] in
      await cleanup?.value
      guard !Task.isCancelled, let deviceID = await resolveDeviceID(), !Task.isCancelled else { return nil }
      let operation = PreparedLivePreview.startOperation(for: deviceID, options: options, service: service)
      return await PreparedLivePreview(deviceID: deviceID, options: options, operationTask: operation, service: service)
    }
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
    case .livePreview(_, _, let task):
      task.cancel()
      cleanupTask = Task {
        await previousCleanup?.value
        await task.value?.discard()
      }
    }
  }
}
