import Foundation
import Observation

@Observable
@MainActor
final class CaptureHistory {
  let repository: CaptureHistoryRepository
  private(set) var entries: [CaptureHistoryEntry] = []
  private(set) var retention = CaptureHistoryRetention()
  private(set) var errorMessage: String?
  private(set) var isLoaded = false
  @ObservationIgnored private var observationTask: Task<Void, Never>?
  @ObservationIgnored private var cleanupTask: Task<Void, Never>?
  @ObservationIgnored private var frameExports: [UUID: Task<Void, Never>] = [:]

  init(repository: CaptureHistoryRepository = CaptureHistoryRepository()) {
    self.repository = repository
  }

  var byteCount: Int64 {
    entries.reduce(0) { $0 + $1.byteCount }
  }

  func start() {
    guard observationTask == nil else { return }
    let repository = repository
    observationTask = Task { [weak self] in
      for await snapshot in await repository.updates() {
        guard !Task.isCancelled, let self else { return }
        entries = snapshot.entries
        retention = snapshot.retention
        errorMessage = snapshot.errorMessage
        isLoaded = true
      }
    }
    cleanupTask = Task {
      while !Task.isCancelled {
        await repository.prune()
        do { try await Task.sleep(for: .seconds(60)) } catch { return }
      }
    }
  }

  func stop() {
    observationTask?.cancel()
    observationTask = nil
    cleanupTask?.cancel()
    cleanupTask = nil
  }

  func recordFrame(url: URL, size: CGSize, deviceProvider: @escaping @Sendable () async -> Device) {
    let exportID = UUID()
    let capturedAt = Date()
    frameExports[exportID] = Task {
      defer { frameExports[exportID] = nil }
      let device = await deviceProvider()
      let id = await repository.begin(kind: .image, devices: [device], at: capturedAt)
      let capture = CaptureMedia(device: device, media: .image(
        url: url, capturedAt: capturedAt, display: DisplayInfo(size: size, densityScale: nil)
      ))
      // The drag session still owns the temporary export file.
      _ = await repository.record(capture, in: id, moveOriginal: false)
      await repository.finish(id)
    }
  }

  func finishFrameExports() async {
    for task in Array(frameExports.values) {
      await task.value
    }
  }
}
