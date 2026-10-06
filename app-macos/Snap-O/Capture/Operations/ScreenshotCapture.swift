import Foundation
import Observation

@Observable
@MainActor
final class ScreenshotCapture: CaptureBatch {
  enum Phase { case starting, capturing, finishing, cancelling }

  let id = UUID()
  let items: [CaptureItem]
  let kind: CaptureKind = .screenshots
  private(set) var isComplete = false
  private(set) var phase: Phase = .starting
  private let screenshots: ScreenshotService
  private let fileStore: FileStore
  private let history: CaptureHistoryRepository?
  private let coordinator: CaptureCoordinator?
  @ObservationIgnored private var work: Task<Void, Never>?
  @ObservationIgnored private var finalization: Task<Void, Never>?
  @ObservationIgnored private var closeTask: Task<Void, Never>?

  init(
    devices: [Device], screenshots: ScreenshotService, fileStore: FileStore,
    history: CaptureHistoryRepository? = nil,
    coordinator: CaptureCoordinator? = nil
  ) {
    items = devices.map(CaptureItem.init)
    self.fileStore = fileStore
    self.screenshots = screenshots
    self.history = history
    self.coordinator = coordinator
  }

  func start() {
    start(reusing: [])
  }

  func start(reusing media: [CaptureMedia]) {
    guard phase == .starting, work == nil else { return }
    phase = .capturing
    work = Task {
      await loadScreenshots(reusing: media)
      isComplete = true
    }
  }

  func waitForCompletion() async {
    await work?.value
  }

  func beginFinalization(discarding: Bool) -> Task<Void, Never> {
    if let finalization { return finalization }
    phase = discarding ? .cancelling : .finishing
    if discarding { work?.cancel() }
    let task = Task {
      if let work {
        // Keep completed screenshots when the remaining requests are cancelled.
        await work.value
      } else {
        for item in items {
          item.update(.cancelled)
        }
        isComplete = true
      }
    }
    finalization = task
    return task
  }

  func close() async {
    if let closeTask { await closeTask.value
      return
    }
    let completion = beginFinalization(discarding: true)
    let task = Task {
      await completion.value
      fileStore.discardPreviews(items.compactMap(\.media))
    }
    closeTask = task
    await task.value
  }

  private func loadScreenshots(reusing media: [CaptureMedia]) async {
    let now = Date()
    for item in items {
      if let capture = media.first(where: {
        $0.device.id == item.device.id && $0.device.connection == item.target
          && item.target?.isValid == true && now.timeIntervalSince($0.media.capturedAt) <= 1
      }) {
        item.update(.ready(capture))
      }
    }
    let missing = items.filter { $0.media == nil }
    guard !missing.isEmpty else {
      Perf.step(.appFirstSnapshot, "using preloaded screenshots")
      return
    }

    let historyID = await history?.begin(kind: .image, devices: missing.map(\.device))
    let screenshots = screenshots
    let coordinator = coordinator
    await withTaskGroup(of: (UUID, Result<CaptureMedia, Error>).self) { group in
      for item in missing {
        let id = item.id
        let device = item.device
        group.addTask {
          var lease: DeviceCaptureLease?
          do {
            let target = try device.requireConnection()
            lease = try await coordinator?.acquire(target: target, for: .screenshot)
            let media = try await screenshots.capture(device: device)
            if let lease { await coordinator?.release(lease) }
            return (id, .success(media))
          } catch {
            if let lease { await coordinator?.release(lease) }
            return (id, .failure(error))
          }
        }
      }
      for await (id, outcome) in group {
        guard let item = items.first(where: { $0.id == id }) else { continue }
        switch outcome {
        case .success(let capture):
          let stored = await history?.record(capture, in: historyID) ?? capture
          item.update(.ready(stored))
        case .failure(let error):
          item.update(error is CancellationError ? .cancelled : .failed(error.localizedDescription))
          if !(error is CancellationError) {
            await history?.recordFailure(deviceID: item.device.id, message: error.localizedDescription, in: historyID)
          }
        }
      }
    }
    if Task.isCancelled { await history?.discardEmpty(historyID) }
    await history?.finish(historyID)
  }
}
