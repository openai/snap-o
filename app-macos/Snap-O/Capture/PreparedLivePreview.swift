import Foundation

/// Holds a startup stream until one renderer takes ownership or the warmup expires.
@MainActor
final class PreparedLivePreview {
  private enum State {
    case available
    case claimed
    case discarded(Task<Void, Never>)
  }

  let deviceID: String
  let options: LivePreviewOptions

  private let operationTask: Task<LivePreviewOperationHandle?, Never>
  private let service: LivePreviewService
  private let lifetime: Duration
  private let sleep: @Sendable (Duration) async throws -> Void
  private var expirationTask: Task<Void, Never>?
  private var state: State = .available

  var isAvailable: Bool {
    if case .available = state { return true }
    return false
  }

  private var isDiscarded: Bool {
    if case .discarded = state { return true }
    return false
  }

  init(
    deviceID: String,
    options: LivePreviewOptions,
    operationTask: Task<LivePreviewOperationHandle?, Never>,
    service: LivePreviewService,
    lifetime: Duration = .seconds(5),
    sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
  ) {
    self.deviceID = deviceID
    self.options = options
    self.operationTask = operationTask
    self.service = service
    self.lifetime = lifetime
    self.sleep = sleep
    scheduleExpiration(afterReadiness: false)
  }

  /// Allow the source's startup timeout before counting down an unused warmup's lifetime.
  func expireAfterReadiness() {
    scheduleExpiration(afterReadiness: true)
  }

  private func scheduleExpiration(afterReadiness: Bool) {
    expirationTask?.cancel()
    expirationTask = Task { [weak self, sleep, lifetime] in
      if afterReadiness { _ = await self?.waitUntilReady() }
      guard !Task.isCancelled else { return }
      do {
        try await sleep(lifetime)
      } catch {
        return
      }
      await self?.discard()
    }
  }

  nonisolated static func startOperation(
    for deviceID: String,
    options: LivePreviewOptions,
    service: LivePreviewService
  ) -> Task<LivePreviewOperationHandle?, Never> {
    Task.detached(priority: .userInitiated) {
      guard !Task.isCancelled else { return nil }
      return try? await service.start(for: deviceID, options: options)
    }
  }

  func take() async -> LivePreviewOperationHandle? {
    switch state {
    case .available:
      state = .claimed
    case .claimed:
      return nil
    case .discarded(let cleanup):
      await cleanup.value
      return nil
    }
    expirationTask?.cancel()
    expirationTask = nil
    let operationTask = operationTask
    let operation = await withTaskCancellationHandler {
      await operationTask.value
    } onCancel: {
      operationTask.cancel()
    }
    guard !Task.isCancelled else {
      if let operation { _ = await service.stop(operation) }
      return nil
    }
    return operation
  }

  func waitUntilReady() async -> Media? {
    guard let operation = await operationTask.value, !isDiscarded else { return nil }
    let media = try? await operation.session.waitUntilReady()
    return isDiscarded ? nil : media
  }

  func discard() async {
    switch state {
    case .claimed:
      return
    case .discarded(let cleanup):
      await cleanup.value
      return
    case .available:
      break
    }
    expirationTask?.cancel()
    expirationTask = nil
    operationTask.cancel()
    let operationTask = operationTask
    let service = service
    let task = Task {
      if let operation = await operationTask.value {
        _ = await service.stop(operation)
      }
    }
    state = .discarded(task)
    await task.value
  }
}
