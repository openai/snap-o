import Foundation
import Observation

@Observable
@MainActor
final class PreparingScreenshotMode {
  private var task: Task<Void, Never>?
  private let captureService: CaptureService
  private let completion: @MainActor ([CaptureMedia], Error?) -> Void

  init(
    captureService: CaptureService,
    completion: @escaping @MainActor ([CaptureMedia], Error?) -> Void
  ) {
    self.captureService = captureService
    self.completion = completion
  }

  func start() {
    task = Task { [weak self] in
      guard let self else { return }
      let (media, error) = await self.captureService.captureScreenshots()
      await self.completion(media, error)
    }
  }

  func cancel() {
    task?.cancel()
  }

  deinit {
    cancel()
  }
}
