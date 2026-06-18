import Foundation
import Observation

@Observable
@MainActor
final class PreparingScreenshotMode {
  @ObservationIgnored private var task: Task<Void, Never>?
  private let captureService: CaptureService
  private let completion: @MainActor (ScreenshotCaptureResult) -> Void

  init(
    captureService: CaptureService,
    completion: @escaping @MainActor (ScreenshotCaptureResult) -> Void
  ) {
    self.captureService = captureService
    self.completion = completion
  }

  func start() {
    task = Task { [weak self] in
      guard let self else { return }
      let result = await captureService.captureScreenshots()
      completion(result)
    }
  }

  func cancel() {
    task?.cancel()
  }
}
