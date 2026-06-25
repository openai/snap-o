import Foundation
import Observation
import SnapODeviceClient

@Observable
@MainActor
final class PreparingScreenshotMode {
  @ObservationIgnored private var task: Task<Void, Never>?
  private let screenshotService: ScreenshotService
  private let devices: [Device]
  private let completion: @MainActor (ScreenshotCaptureResult) -> Void

  init(
    screenshotService: ScreenshotService,
    devices: [Device],
    completion: @escaping @MainActor (ScreenshotCaptureResult) -> Void
  ) {
    self.screenshotService = screenshotService
    self.devices = devices
    self.completion = completion
  }

  func start() {
    task = Task { [weak self] in
      guard let self else { return }
      let result = await screenshotService.capture(for: devices)
      completion(result)
    }
  }

  func cancel() {
    task?.cancel()
  }
}
