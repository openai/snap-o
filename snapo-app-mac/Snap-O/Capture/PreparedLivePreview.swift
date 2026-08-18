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
    lifetime: Duration = .seconds(5)
  ) {
    self.deviceID = deviceID
    self.options = options
    self.operationTask = operationTask
    self.service = service
    expirationTask = Task { [weak self] in
      do {
        try await Task.sleep(for: lifetime)
      } catch {
        return
      }
      await self?.discard()
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
