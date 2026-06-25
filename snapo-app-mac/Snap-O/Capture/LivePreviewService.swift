import Foundation

struct LivePreviewOptions {
  let showsTouches: Bool
}

struct LivePreviewOperationHandle {
  let id: UUID
  let deviceID: String
  let session: LivePreviewSession
}

actor LivePreviewService {
  private struct Operation {
    let deviceID: String
    let session: LivePreviewSession
    let showTouchesOverride: ShowTouchesOverride
    let lease: DeviceCaptureLease
  }

  private let adb: ADBService
  private let coordinator: CaptureCoordinator

  private var operations: [UUID: Operation] = [:]
  private var pendingOperationIDs: Set<UUID> = []
  private var cleanupOperationIDs: Set<UUID> = []
  private var isShuttingDown = false
  private var shutdownTask: Task<Void, Never>?

  init(adb: ADBService, coordinator: CaptureCoordinator) {
    self.adb = adb
    self.coordinator = coordinator
  }

  func start(
    for deviceID: String,
    options: LivePreviewOptions
  ) async throws -> LivePreviewOperationHandle {
    guard !isShuttingDown else { throw CaptureCoordinationError.closed }

    let operationID = UUID()
    pendingOperationIDs.insert(operationID)
    defer { pendingOperationIDs.remove(operationID) }

    let lease = try await coordinator.acquire(
      deviceIDs: [deviceID],
      for: .livePreview
    )
    guard !Task.isCancelled, !isShuttingDown else {
      await coordinator.release(lease)
      throw CancellationError()
    }

    let showTouchesOverride = await ShowTouchesOverride.apply(
      deviceID: deviceID,
      enabled: options.showsTouches,
      using: adb
    )
    let session: LivePreviewSession
    do {
      session = try await LivePreviewSession(deviceID: deviceID, adb: adb)
    } catch {
      await showTouchesOverride.restore(using: adb)
      await coordinator.release(lease)
      throw error
    }

    guard !Task.isCancelled, !isShuttingDown else {
      await session.cancel()
      _ = await session.waitUntilStop()
      await showTouchesOverride.restore(using: adb)
      await coordinator.release(lease)
      throw CancellationError()
    }

    operations[operationID] = Operation(
      deviceID: deviceID,
      session: session,
      showTouchesOverride: showTouchesOverride,
      lease: lease
    )
    return LivePreviewOperationHandle(
      id: operationID,
      deviceID: deviceID,
      session: session
    )
  }

  func stop(_ handle: LivePreviewOperationHandle) async -> Error? {
    guard let operation = operations.removeValue(forKey: handle.id) else { return nil }
    cleanupOperationIDs.insert(handle.id)
    defer { cleanupOperationIDs.remove(handle.id) }

    let error = await stop(operation)
    await coordinator.release(operation.lease)
    return error
  }

  func shutdown() async {
    if let shutdownTask {
      await shutdownTask.value
      return
    }

    isShuttingDown = true
    let task = Task { await performShutdown() }
    shutdownTask = task
    await task.value
  }

  private func stop(_ operation: Operation) async -> Error? {
    await operation.session.cancel()
    let error = await operation.session.waitUntilStop()
    await operation.showTouchesOverride.restore(using: adb)
    return error
  }

  private func performShutdown() async {
    let activeOperations = operations
    operations.removeAll()

    for operation in activeOperations.values {
      _ = await stop(operation)
      await coordinator.release(operation.lease)
    }
    while !pendingOperationIDs.isEmpty || !cleanupOperationIDs.isEmpty {
      await Task.yield()
    }
  }
}
