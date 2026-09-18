import Foundation

struct LivePreviewOptions: Equatable {
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
  private let bootRetrySleep: @Sendable (Duration) async throws -> Void
  private var bootWaitTasks: [UUID: Task<Void, Error>] = [:]

  private var operations: [UUID: Operation] = [:]
  private var pendingOperationIDs: Set<UUID> = []
  private var cleanupOperationIDs: Set<UUID> = []
  private var isShuttingDown = false
  private var shutdownTask: Task<Void, Never>?

  init(
    adb: ADBService,
    coordinator: CaptureCoordinator,
    bootRetrySleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
  ) {
    self.adb = adb
    self.coordinator = coordinator
    self.bootRetrySleep = bootRetrySleep
  }

  func start(
    for deviceID: String,
    options: LivePreviewOptions
  ) async throws -> LivePreviewOperationHandle {
    guard !isShuttingDown else { throw CaptureCoordinationError.closed }

    let operationID = UUID()
    pendingOperationIDs.insert(operationID)
    defer { pendingOperationIDs.remove(operationID) }

    try await waitUntilBootComplete(for: deviceID)

    let lease = try await coordinator.acquire(
      deviceIDs: [deviceID],
      for: .livePreview
    )
    guard !Task.isCancelled, !isShuttingDown else {
      await coordinator.release(lease)
      throw CancellationError()
    }

    async let applyingShowTouches = ShowTouchesOverride.apply(
      deviceID: deviceID,
      enabled: options.showsTouches,
      using: adb
    )
    let session: LivePreviewSession
    do {
      session = try await LivePreviewSession(deviceID: deviceID, adb: adb)
    } catch {
      let showTouchesOverride = await applyingShowTouches
      await showTouchesOverride.restore(using: adb)
      await coordinator.release(lease)
      throw error
    }
    let showTouchesOverride = await applyingShowTouches

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
    for task in bootWaitTasks.values {
      task.cancel()
    }
    let task = Task { await performShutdown() }
    shutdownTask = task
    await task.value
  }

  private func waitUntilBootComplete(for deviceID: String) async throws {
    guard !isShuttingDown else { throw CaptureCoordinationError.closed }
    let id = UUID()
    // Keep discovery cancellable during both ADB requests and retry delays.
    let task = Task { [adb, sleep = bootRetrySleep] in
      let exec = await adb.exec()
      var delay = Duration.seconds(1)
      while true {
        try Task.checkCancellation()
        do {
          if try await exec.isBootComplete(deviceID: deviceID) { return }
        } catch is CancellationError {
          throw CancellationError()
        } catch {
          // ADB can reject commands or time out while Android is booting.
        }
        try await sleep(delay)
        delay = min(delay * 2, .seconds(10))
      }
    }
    bootWaitTasks[id] = task
    defer { bootWaitTasks.removeValue(forKey: id) }
    try await withTaskCancellationHandler {
      try await task.value
    } onCancel: {
      task.cancel()
    }
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
