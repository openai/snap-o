import Foundation
import Observation
import SnapODeviceClient

@Observable
@MainActor
final class PreparingScreenshotMode {
  @ObservationIgnored private var task: Task<Void, Never>?
  private let screenshotService: ScreenshotService
  private let devices: [Device]
  private let preloadedTask: Task<ScreenshotCaptureResult, Never>?
  private let completion: @MainActor (ScreenshotCaptureResult) -> Void

  init(
    screenshotService: ScreenshotService,
    devices: [Device],
    preloadedTask: Task<ScreenshotCaptureResult, Never>? = nil,
    completion: @escaping @MainActor (ScreenshotCaptureResult) -> Void
  ) {
    self.screenshotService = screenshotService
    self.devices = devices
    self.preloadedTask = preloadedTask
    self.completion = completion
  }

  func start() {
    task = Task { [weak self] in
      guard let self else { return }
      let result = await loadScreenshots()
      guard !Task.isCancelled else { return }
      completion(result)
    }
  }

  func cancel() {
    task?.cancel()
    preloadedTask?.cancel()
  }

  private func loadScreenshots() async -> ScreenshotCaptureResult {
    guard let preloadedTask else { return await screenshotService.capture(for: devices) }
    let preloaded = await withTaskCancellationHandler {
      await preloadedTask.value
    } onCancel: {
      preloadedTask.cancel()
    }
    guard !Task.isCancelled else { return ScreenshotCaptureResult(media: [], failures: []) }

    let now = Date()
    let deviceIDs = Set(devices.map(\.id))
    let fresh = preloaded.media.filter {
      deviceIDs.contains($0.device.id) && now.timeIntervalSince($0.media.capturedAt) <= 1
    }
    let freshDeviceIDs = Set(fresh.map(\.device.id))
    let missing = devices.filter { !freshDeviceIDs.contains($0.id) }
    guard !missing.isEmpty else {
      Perf.step(.appFirstSnapshot, "using preloaded screenshots")
      return ScreenshotCaptureResult(media: fresh, failures: [])
    }

    let refreshed = await screenshotService.capture(for: missing)
    let captures = Dictionary(uniqueKeysWithValues: (fresh + refreshed.media).map { ($0.device.id, $0) })
    return ScreenshotCaptureResult(
      media: devices.compactMap { captures[$0.id] },
      failures: refreshed.failures
    )
  }
}
