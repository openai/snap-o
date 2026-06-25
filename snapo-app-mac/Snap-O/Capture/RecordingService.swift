@preconcurrency import AVKit
import CoreGraphics
import Foundation
import SnapODeviceClient

struct RecordingOptions {
  let recordsBugReport: Bool
  let showsTouches: Bool
}

struct RecordingOperationHandle: Hashable {
  let id: UUID
  fileprivate let completion: RecordingOperationCompletion

  static func == (lhs: RecordingOperationHandle, rhs: RecordingOperationHandle) -> Bool {
    lhs.id == rhs.id
  }

  func hash(into hasher: inout Hasher) {
    hasher.combine(id)
  }
}

struct RecordingOperationResult {
  let media: [CaptureMedia]
  let error: Error?
}

private enum RecordingOperationOutcome {
  case completed(RecordingOperationResult)
  case cancelled
}

private actor RecordingOperationCompletion {
  private var outcome: RecordingOperationOutcome?
  private var waiters: [CheckedContinuation<RecordingOperationOutcome, Never>] = []

  func wait() async -> RecordingOperationOutcome {
    if let outcome { return outcome }
    return await withCheckedContinuation { continuation in
      waiters.append(continuation)
    }
  }

  func resolve(_ outcome: RecordingOperationOutcome) {
    guard self.outcome == nil else { return }
    self.outcome = outcome
    let waiters = waiters
    self.waiters.removeAll()
    for waiter in waiters {
      waiter.resume(returning: outcome)
    }
  }
}

private struct RecordingLifecycleError: LocalizedError {
  let errorDescription: String?
}

actor RecordingService {
  private struct Entry {
    let device: Device
    let session: RecordingSession
    let showTouchesOverride: ShowTouchesOverride
  }

  private struct SessionMonitor {
    let session: RecordingSession
    let task: Task<Void, Never>
  }

  private struct Operation {
    let entries: [Entry]
    let lease: DeviceCaptureLease
    let completion: RecordingOperationCompletion
    var sessionMonitors: [SessionMonitor]
  }

  private let adb: ADBService
  private let fileStore: FileStore
  private let coordinator: CaptureCoordinator
  private let timestampSource = CaptureTimestampSource()

  private var operations: [UUID: Operation] = [:]
  private var pendingOperationIDs: Set<UUID> = []
  private var cleanupOperationIDs: Set<UUID> = []
  private var isShuttingDown = false
  private var shutdownTask: Task<Void, Never>?

  init(
    adb: ADBService,
    fileStore: FileStore,
    coordinator: CaptureCoordinator
  ) {
    self.adb = adb
    self.fileStore = fileStore
    self.coordinator = coordinator
  }

  func start(
    for devices: [Device],
    options: RecordingOptions
  ) async throws -> RecordingOperationHandle {
    guard !isShuttingDown else { throw CaptureCoordinationError.closed }

    var seenDeviceIDs = Set<String>()
    let devices = devices.filter { seenDeviceIDs.insert($0.id).inserted }
    let operationID = UUID()
    pendingOperationIDs.insert(operationID)
    defer { pendingOperationIDs.remove(operationID) }

    let lease = try await coordinator.acquire(
      deviceIDs: devices.map(\.id),
      for: .recording
    )
    guard !Task.isCancelled, !isShuttingDown else {
      await coordinator.release(lease)
      throw CancellationError()
    }

    let (entries, encounteredError) = await startEntries(
      devices: devices,
      options: options
    )
    if let error = encounteredError ?? ((Task.isCancelled || isShuttingDown) ? CancellationError() : nil) {
      await discard(entries)
      await coordinator.release(lease)
      throw error
    }

    let completion = RecordingOperationCompletion()
    let handle = RecordingOperationHandle(
      id: operationID,
      completion: completion
    )
    operations[operationID] = Operation(
      entries: entries,
      lease: lease,
      completion: completion,
      sessionMonitors: []
    )
    operations[operationID]?.sessionMonitors = entries.map { entry in
      SessionMonitor(
        session: entry.session,
        task: monitorSession(entry, operationID: operationID)
      )
    }
    return handle
  }

  func waitForCompletion(
    of handle: RecordingOperationHandle
  ) async -> RecordingOperationResult? {
    switch await handle.completion.wait() {
    case .completed(let result): result
    case .cancelled: nil
    }
  }

  func updateConnectedDeviceIDs(
    _ connectedDeviceIDs: Set<String>,
    for handle: RecordingOperationHandle
  ) async {
    guard let operation = operations[handle.id] else { return }
    guard let disconnectedEntry = operation.entries.first(where: {
      !connectedDeviceIDs.contains($0.device.id)
    }) else { return }

    await complete(
      handle.id,
      error: RecordingLifecycleError(
        errorDescription: "Recording ended because \(disconnectedEntry.device.displayTitle) disconnected."
      )
    )
  }

  func finish(_ handle: RecordingOperationHandle) async {
    await complete(handle.id, error: nil)
    _ = await handle.completion.wait()
  }

  func cancel(_ handle: RecordingOperationHandle) async {
    guard let operation = takeOperation(handle.id) else {
      _ = await handle.completion.wait()
      return
    }
    cleanupOperationIDs.insert(handle.id)
    defer { cleanupOperationIDs.remove(handle.id) }

    await discard(operation.entries)
    await coordinator.release(operation.lease)
    await operation.completion.resolve(.cancelled)
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

  private func startEntries(
    devices: [Device],
    options: RecordingOptions
  ) async -> ([Entry], Error?) {
    let adb = adb
    var entries: [Entry] = []
    var encounteredError: Error?

    await withTaskGroup(of: (Device, ShowTouchesOverride, Result<RecordingSession, Error>).self) { group in
      for device in devices {
        group.addTask {
          let showTouchesOverride = await ShowTouchesOverride.apply(
            deviceID: device.id,
            enabled: options.showsTouches,
            using: adb
          )
          let exec = await adb.exec()
          do {
            let session = try await exec.startScreenrecord(
              deviceID: device.id,
              bugReport: options.recordsBugReport
            )
            return (device, showTouchesOverride, .success(session))
          } catch {
            await showTouchesOverride.restore(using: adb)
            return (device, showTouchesOverride, .failure(error))
          }
        }
      }

      for await (device, showTouchesOverride, result) in group {
        switch result {
        case .success(let session):
          entries.append(
            Entry(
              device: device,
              session: session,
              showTouchesOverride: showTouchesOverride
            )
          )
        case .failure(let error):
          encounteredError = encounteredError ?? error
        }
      }
    }
    return (entries, encounteredError)
  }

  private func collectMedia(
    from entries: [Entry],
    endedSession: RecordingSession? = nil
  ) async -> ([CaptureMedia], Error?) {
    var media: [CaptureMedia] = []
    var encounteredError: Error?

    await withTaskGroup(of: Result<CaptureMedia?, Error>.self) { group in
      for entry in entries {
        group.addTask {
          do {
            let capture = try await self.stop(
              entry,
              sessionHasEnded: entry.session === endedSession
            )
            return .success(capture)
          } catch {
            return .failure(error)
          }
        }
      }

      for await result in group {
        switch result {
        case .success(let capture?):
          media.append(capture)
        case .success(nil):
          continue
        case .failure(let error):
          encounteredError = encounteredError ?? error
        }
      }
    }
    return (media, encounteredError)
  }

  private func monitorSession(
    _ entry: Entry,
    operationID: UUID
  ) -> Task<Void, Never> {
    Task { [weak self] in
      let failureDescription: String?
      do {
        try await entry.session.waitUntilStopped()
        failureDescription = nil
      } catch {
        failureDescription = error.localizedDescription
      }
      guard !Task.isCancelled else { return }
      await self?.sessionEnded(
        operationID: operationID,
        entry: entry,
        failureDescription: failureDescription
      )
    }
  }

  private func sessionEnded(
    operationID: UUID,
    entry: Entry,
    failureDescription: String?
  ) async {
    guard operations[operationID] != nil else { return }
    let detail = failureDescription.map { " (\($0))" } ?? ""
    await complete(
      operationID,
      error: RecordingLifecycleError(
        errorDescription: "Recording on \(entry.device.displayTitle) ended unexpectedly\(detail)."
      ),
      endedSession: entry.session
    )
  }

  private func complete(
    _ operationID: UUID,
    error lifecycleError: Error?,
    endedSession: RecordingSession? = nil
  ) async {
    guard let operation = takeOperation(
      operationID,
      preservingMonitorFor: endedSession
    ) else { return }
    cleanupOperationIDs.insert(operationID)
    defer { cleanupOperationIDs.remove(operationID) }

    let (media, captureError) = await collectMedia(
      from: operation.entries,
      endedSession: endedSession
    )
    await coordinator.release(operation.lease)
    await operation.completion.resolve(
      .completed(
        RecordingOperationResult(
          media: media,
          error: lifecycleError ?? captureError
        )
      )
    )
  }

  private func takeOperation(
    _ operationID: UUID,
    preservingMonitorFor session: RecordingSession? = nil
  ) -> Operation? {
    guard let operation = operations.removeValue(forKey: operationID) else { return nil }
    for monitor in operation.sessionMonitors where monitor.session !== session {
      monitor.task.cancel()
    }
    return operation
  }

  private func stop(
    _ entry: Entry,
    sessionHasEnded: Bool
  ) async throws -> CaptureMedia? {
    let exec = await adb.exec()
    let capturedAt = await timestampSource.next()
    let destination = fileStore.makePreviewDestination(
      deviceID: entry.device.id,
      capturedAt: capturedAt,
      kind: .video
    )

    do {
      if sessionHasEnded {
        try await exec.collectScreenrecord(session: entry.session, savingTo: destination)
      } else {
        try await exec.stopScreenrecord(session: entry.session, savingTo: destination)
      }
    } catch {
      await entry.showTouchesOverride.restore(using: adb)
      throw error
    }
    await entry.showTouchesOverride.restore(using: adb)

    let asset = AVURLAsset(url: destination)
    let duration = try await asset.load(.duration)
    guard duration.seconds > 0 else { return nil }

    let adb = adb
    let device = entry.device
    let densityTask = Task<CGFloat?, Never> {
      let density = try? await adb.exec().displayDensity(deviceID: device.id)
      return density.map { CGFloat($0) }
    }
    guard let media = try await Media.video(
      from: asset,
      url: destination,
      capturedAt: capturedAt,
      densityProvider: { await densityTask.value }
    ) else {
      return nil
    }
    return CaptureMedia(device: device, media: media)
  }

  private func discard(_ entries: [Entry]) async {
    let adb = adb
    let cleanupTask = Task.detached(priority: .utility) {
      await withTaskGroup(of: Void.self) { group in
        for entry in entries {
          group.addTask {
            await adb.exec().cancelScreenrecord(session: entry.session)
            await entry.showTouchesOverride.restore(using: adb)
          }
        }
      }
    }
    await cleanupTask.value
  }

  private func performShutdown() async {
    let activeOperations = operations
    operations.removeAll()

    for operation in activeOperations.values {
      for monitor in operation.sessionMonitors {
        monitor.task.cancel()
      }
      await discard(operation.entries)
      await coordinator.release(operation.lease)
      await operation.completion.resolve(.cancelled)
    }
    while !pendingOperationIDs.isEmpty || !cleanupOperationIDs.isEmpty {
      await Task.yield()
    }
  }
}
