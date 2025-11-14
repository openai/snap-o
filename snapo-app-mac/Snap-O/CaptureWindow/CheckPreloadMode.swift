import Foundation
import Observation

@Observable
@MainActor
final class CheckPreloadMode {
  enum Outcome {
    case found([CaptureMedia])
    case missing
  }

  private var task: Task<Void, Never>?
  private let captureService: CaptureService
  private let completion: @MainActor (Outcome) -> Void

  init(
    captureService: CaptureService,
    completion: @escaping @MainActor (Outcome) -> Void
  ) {
    self.captureService = captureService
    self.completion = completion
  }

  func start() {
    task = Task { [weak self] in
      guard let self else { return }
      if let media = await self.loadPreloadedScreenshots() {
        await self.completion(.found(media))
      } else {
        await self.completion(.missing)
      }
    }
  }

  func cancel() {
    task?.cancel()
  }

  deinit {
    cancel()
  }

  private func loadPreloadedScreenshots() async -> [CaptureMedia]? {
    Perf.step(.appFirstSnapshot, "Starting initial preview load")
    Perf.step(.appFirstSnapshot, "consume preloaded screenshot")

    let preloaded = await captureService.consumeAllPreloadedScreenshots()
    guard !preloaded.isEmpty else {
      Perf.step(.appFirstSnapshot, "Preload missing; refreshing preview")
      return nil
    }

    Perf.step(.appFirstSnapshot, "Using preloaded screenshot")
    return preloaded
  }
}
