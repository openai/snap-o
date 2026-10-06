import Dependencies
import Foundation
import Observation

@Observable
@MainActor
final class CaptureHistory {
  let repository: CaptureHistoryRepository
  private let writeFrame: @Sendable (CaptureMedia) async -> Void
  private(set) var entries: [CaptureHistoryEntry] = []
  private(set) var retention = CaptureHistoryRetention()
  private(set) var errorMessage: String?
  private(set) var isLoaded = false
  @ObservationIgnored private var observationTask: Task<Void, Never>?
  @ObservationIgnored private var cleanupTask: Task<Void, Never>?
  @ObservationIgnored private var pendingUpdate: (id: UUID, task: Task<Void, Never>)?
  @ObservationIgnored private var shutdownTask: Task<Void, Never>?
  @Dependency(\.continuousClock)
  @ObservationIgnored private var clock

  init(
    repository: CaptureHistoryRepository = CaptureHistoryRepository(),
    writeFrame: (@Sendable (CaptureMedia) async -> Void)? = nil
  ) {
    self.repository = repository
    self.writeFrame = writeFrame ?? { await repository.recordFrame($0) }
  }

  var byteCount: Int64 {
    entries.reduce(0) { $0 + $1.byteCount }
  }

  func name(for captureID: UUID) -> String? {
    entries.first { $0.items.contains { $0.captureID == captureID } }?.name
  }

  func start() {
    guard observationTask == nil, shutdownTask == nil else { return }
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
    cleanupTask = Task { [clock] in
      while !Task.isCancelled {
        await repository.prune()
        do { try await clock.sleep(for: .seconds(60)) } catch { return }
      }
    }
  }

  /// Reject new writes, then wait for pending writes and background tasks.
  func shutdown() async {
    if let shutdownTask {
      await shutdownTask.value
      return
    }
    let observation = observationTask
    let cleanup = cleanupTask
    let update = pendingUpdate?.task
    observation?.cancel()
    cleanup?.cancel()
    observationTask = nil
    cleanupTask = nil
    let task = Task {
      await observation?.value
      await cleanup?.value
      await update?.value
    }
    shutdownTask = task
    await task.value
  }

  /// Queue each write before returning. Keep writes in order and wait for them on shutdown.
  @discardableResult
  func update(_ operation: @escaping @Sendable (CaptureHistoryRepository) async -> Void) -> Task<Void, Never>? {
    guard shutdownTask == nil else { return nil }
    let id = UUID()
    let previous = pendingUpdate?.task
    let task = Task {
      await previous?.value
      await operation(repository)
      if pendingUpdate?.id == id { pendingUpdate = nil }
    }
    pendingUpdate = (id, task)
    return task
  }

  func recordFrame(_ capture: CaptureMedia) {
    let writeFrame = writeFrame
    update { _ in await writeFrame(capture) }
  }
}
