import Foundation
import Observation
import SnapODeviceClient

@Observable
@MainActor
final class CheckPreloadMode {
  enum Outcome {
    case found([CaptureMedia])
    case missing
  }

  @ObservationIgnored private var task: Task<Void, Never>?
  private let screenshotService: ScreenshotService
  private let devices: [Device]
  private let completion: @MainActor (Outcome) -> Void

  init(
    screenshotService: ScreenshotService,
    devices: [Device],
    completion: @escaping @MainActor (Outcome) -> Void
  ) {
    self.screenshotService = screenshotService
    self.devices = devices
    self.completion = completion
  }

  func start() {
    task = Task { [weak self] in
      guard let self else { return }
      if let media = await loadPreloadedScreenshots() {
        guard !Task.isCancelled else { return }
        completion(.found(media))
      } else {
        guard !Task.isCancelled else { return }
        completion(.missing)
      }
    }
  }

  func cancel() {
    task?.cancel()
    task = nil
  }

  private func loadPreloadedScreenshots() async -> [CaptureMedia]? {
    await screenshotService.preload(for: devices)
    Perf.step(.appFirstSnapshot, "Starting initial preview load")
    Perf.step(.appFirstSnapshot, "consume preloaded screenshot")

    let preloaded = await screenshotService.consumePreloaded()
    guard !preloaded.isEmpty else {
      Perf.step(.appFirstSnapshot, "Preload missing; refreshing preview")
      return nil
    }

    Perf.step(.appFirstSnapshot, "Using preloaded screenshot")
    return preloaded
  }
}
