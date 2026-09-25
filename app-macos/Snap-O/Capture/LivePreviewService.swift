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
    let showTouchesOverride: ShowTouchesOverride?
    let setupTask: Task<ShowTouchesOverride?, Never>?
    let lease: DeviceCaptureLease
  }

  typealias PhysicalSession = @MainActor @Sendable (String) -> LivePreviewSession
  private let physicalSession: PhysicalSession?
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
    bootRetrySleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
    physicalSession: PhysicalSession? = nil
  ) {
    self.physicalSession = physicalSession
    self.adb = adb
    self.coordinator = coordinator
    self.bootRetrySleep = bootRetrySleep
  }

  func start(
    for deviceID: String,
    options: LivePreviewOptions
  ) async throws -> LivePreviewOperationHandle {
    #if PERF_TRACING
    let timing = Perf.startupBegin("preview service start", deviceID: deviceID)
    defer { Perf.startupEnd(timing) }
    #endif
    guard !isShuttingDown else { throw CaptureCoordinationError.closed }

    let operationID = UUID()
    pendingOperationIDs.insert(operationID)
    defer { pendingOperationIDs.remove(operationID) }

    let isEmulator = EmulatorGRPCEndpoint.isEmulator(deviceID)
    if !isEmulator { try await waitUntilBootComplete(for: deviceID) }

    let lease = try await coordinator.acquire(
      deviceIDs: [deviceID],
      for: .livePreview
    )
    guard !Task.isCancelled, !isShuttingDown else {
      await coordinator.release(lease)
      throw CancellationError()
    }

    #if PERF_TRACING
    Perf.startupEvent("preview lease acquired", deviceID: deviceID)
    #endif
    if isEmulator {
      return try await startEmulator(deviceID: deviceID, operationID: operationID, lease: lease, options: options)
    }

    async let applyingShowTouches = ShowTouchesOverride.apply(
      deviceID: deviceID,
      enabled: options.showsTouches,
      using: adb
    )
    let session: LivePreviewSession
    do {
      session = try await makeSession(for: deviceID)
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
      setupTask: Task {
        let exec = await adb.exec()
        if let density = try? await exec.displayDensity(deviceID: deviceID), !Task.isCancelled {
          await session.updateDensityScale(CGFloat(density))
        }
        return showTouchesOverride
      },
      lease: lease
    )
    return LivePreviewOperationHandle(
      id: operationID,
      deviceID: deviceID,
      session: session
    )
  }

  private func makeSession(for deviceID: String) async throws -> LivePreviewSession {
    if let physicalSession { return await physicalSession(deviceID) }
    #if PERF_TRACING
    let timing = Perf.startupBegin("physical session setup", deviceID: deviceID)
    defer { Perf.startupEnd(timing) }
    #endif
    let exec = await adb.exec()
    let stream = try await exec.startScreenStream(deviceID: deviceID)
    guard !Task.isCancelled else {
      stream.close()
      throw CancellationError()
    }
    return await LivePreviewSession(deviceID: deviceID, densityScale: nil, source: ADBPreviewFrameSource(stream: stream))
  }

  private func startEmulator(
    deviceID: String,
    operationID: UUID,
    lease: DeviceCaptureLease,
    options: LivePreviewOptions
  ) async throws -> LivePreviewOperationHandle {
    let session = await LivePreviewSession(
      deviceID: deviceID, densityScale: nil, source: EmulatorPreviewFrameSource(deviceID: deviceID)
    )
    guard !Task.isCancelled, !isShuttingDown else {
      await session.cancel()
      await coordinator.release(lease)
      throw CancellationError()
    }
    // Frames can arrive while Android services are still booting.
    let setup = Task<ShowTouchesOverride?, Never> {
      do { try await waitUntilBootComplete(for: deviceID) } catch { return nil }
      guard !Task.isCancelled else { return nil }
      let exec = await adb.exec()
      while !Task.isCancelled {
        do {
          let density = try await exec.displayDensity(deviceID: deviceID)
          await session.updateDensityScale(CGFloat(density))
          break
        } catch {
          do { try await bootRetrySleep(.seconds(1)) } catch { return nil }
        }
      }
      guard !Task.isCancelled else { return nil }
      _ = try? await exec.keyEvent(deviceID: deviceID, keyCode: "KEYCODE_WAKEUP")
      guard !Task.isCancelled else { return nil }
      return await ShowTouchesOverride.apply(deviceID: deviceID, enabled: options.showsTouches, using: adb)
    }
    operations[operationID] = Operation(
      deviceID: deviceID, session: session, showTouchesOverride: nil, setupTask: setup, lease: lease
    )
    return LivePreviewOperationHandle(id: operationID, deviceID: deviceID, session: session)
  }

  func waitUntilInteractive(_ handle: LivePreviewOperationHandle) async -> Bool {
    guard let operation = operations[handle.id] else { return false }
    if let setup = operation.setupTask, await setup.value == nil { return false }
    return !Task.isCancelled && operations[handle.id] != nil
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
    operation.setupTask?.cancel()
    await operation.session.cancel()
    let error = await operation.session.waitUntilStop()
    let showTouchesOverride = await operation.setupTask?.value ?? operation.showTouchesOverride
    await showTouchesOverride?.restore(using: adb)
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
