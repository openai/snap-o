@preconcurrency import AVKit
import CoreGraphics
import Foundation

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
    var touchRestoration: Task<Void, Never>?

    func restoreTouches(using adb: ADBService) async {
      if let touchRestoration {
        await touchRestoration.value
      } else {
        await showTouchesOverride.restore(using: adb, timeout: .seconds(3))
      }
    }
  }

  private struct SessionMonitor {
    let session: RecordingSession
    let task: Task<Void, Never>
  }

  private struct Operation {
    var entries: [Entry]
    let lease: DeviceCaptureLease
    let completion: RecordingOperationCompletion
    var sessionMonitors: [SessionMonitor]
    let historyID: UUID?
    var endedDeviceErrors: [String: String] = [:]
  }

  private let adb: ADBService
  private let fileStore: FileStore
  private let coordinator: CaptureCoordinator
  private let history: CaptureHistoryRepository?
  private let timestampSource = CaptureTimestampSource()

  private var operations: [UUID: Operation] = [:]
  private var pendingOperationIDs: Set<UUID> = []
  private var cleanupOperationIDs: Set<UUID> = []
  private var isShuttingDown = false
  private var shutdownTask: Task<Void, Never>?

  init(
    adb: ADBService,
    fileStore: FileStore,
    coordinator: CaptureCoordinator,
    history: CaptureHistoryRepository? = nil
  ) {
    self.adb = adb
    self.fileStore = fileStore
    self.coordinator = coordinator
    self.history = history
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
    let historyID = await history?.begin(kind: .video, devices: devices)
    guard !Task.isCancelled, !isShuttingDown else {
      await discard(entries)
      await history?.discardEmpty(historyID)
      await coordinator.release(lease)
      throw CancellationError()
    }
    let handle = RecordingOperationHandle(
      id: operationID,
      completion: completion
    )
    operations[operationID] = Operation(
      entries: entries,
      lease: lease,
      completion: completion,
      sessionMonitors: [],
      historyID: historyID
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
    for entry in operation.entries where !connectedDeviceIDs.contains(entry.device.id) {
      entry.session.close()
      await sessionEnded(
        operationID: handle.id,
        entry: entry,
        message: "Recording ended because \(entry.device.displayTitle) disconnected."
      )
    }
  }

  func finish(_ handle: RecordingOperationHandle) async {
    await complete(handle.id)
    _ = await handle.completion.wait()
  }

  func cancel(_ handle: RecordingOperationHandle) async {
    guard let operation = takeOperation(handle.id) else {
      _ = await handle.completion.wait()
      return
    }
    cleanupOperationIDs.insert(handle.id)
    defer { cleanupOperationIDs.remove(handle.id) }

    await discard(operation.entries, endedDeviceIDs: Set(operation.endedDeviceErrors.keys))
    await history?.discardEmpty(operation.historyID)
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
            using: adb,
            timeout: .seconds(3)
          )
          let exec = await adb.exec()
          do {
            let session = try await exec.startScreenrecord(
              deviceID: device.id,
              bugReport: options.recordsBugReport
            )
            return (device, showTouchesOverride, .success(session))
          } catch {
            await showTouchesOverride.restore(using: adb, timeout: .seconds(3))
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
    historyID: UUID?,
    endedDeviceErrors: [String: String]
  ) async -> ([CaptureMedia], Error?) {
    var media: [CaptureMedia] = []
    var errors = endedDeviceErrors

    await withTaskGroup(of: (Device, Result<(CaptureMedia?, Error?), Error>).self) { group in
      for entry in entries {
        group.addTask {
          do {
            let capture = try await self.stop(
              entry,
              sessionHasEnded: endedDeviceErrors[entry.device.id] != nil
            )
            return (entry.device, .success(capture))
          } catch {
            return (entry.device, .failure(error))
          }
        }
      }

      for await (device, result) in group {
        switch result {
        case .success(let (capture, warning)):
          if let capture {
            let stored = await history?.record(capture, in: historyID) ?? capture
            media.append(stored)
          }
          let failure = warning?.localizedDescription ?? (capture == nil ? "No playable recording was received." : nil)
          if let failure {
            let detail = "\(device.displayTitle): \(failure)"
            let message = errors[device.id].map { "\($0)\n\(detail)" } ?? detail
            errors[device.id] = message
            if capture == nil {
              await history?.recordFailure(deviceID: device.id, message: message, in: historyID)
            }
          }
        case .failure(let error):
          let detail = "\(device.displayTitle): \(error.localizedDescription)"
          let message = errors[device.id].map { "\($0)\n\(detail)" } ?? detail
          errors[device.id] = message
          await history?.recordFailure(deviceID: device.id, message: message, in: historyID)
        }
      }
    }
    let error = errors.isEmpty ? nil : RecordingLifecycleError(
      errorDescription: errors.sorted { $0.key < $1.key }.map(\.value).joined(separator: "\n")
    )
    return (media, error)
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
    let detail = failureDescription.map { " (\($0))" } ?? ""
    await sessionEnded(
      operationID: operationID,
      entry: entry,
      message: "Recording on \(entry.device.displayTitle) ended unexpectedly\(detail)."
    )
  }

  private func sessionEnded(
    operationID: UUID,
    entry: Entry,
    message: String
  ) async {
    guard var operation = operations[operationID],
          operation.endedDeviceErrors[entry.device.id] == nil else { return }
    guard let index = operation.entries.firstIndex(where: { $0.device.id == entry.device.id }) else { return }
    let restoration = Task { await entry.showTouchesOverride.restore(using: adb, timeout: .seconds(3)) }
    operation.entries[index].touchRestoration = restoration
    operation.endedDeviceErrors[entry.device.id] = message
    operations[operationID] = operation
    await restoration.value
    guard operations[operationID] != nil else { return }
    await history?.recordFailure(deviceID: entry.device.id, message: message, in: operation.historyID)

    // Keep Stop available until every device has ended or the user finishes the group.
    if operation.endedDeviceErrors.count == operation.entries.count {
      await complete(operationID, endedSession: entry.session)
    }
  }

  private func complete(
    _ operationID: UUID,
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
      historyID: operation.historyID,
      endedDeviceErrors: operation.endedDeviceErrors
    )
    await history?.finish(operation.historyID)
    await coordinator.release(operation.lease)
    await operation.completion.resolve(
      .completed(
        RecordingOperationResult(
          media: media,
          error: captureError
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
  ) async throws -> (CaptureMedia?, Error?) {
    let exec = await adb.exec()
    let capturedAt = await timestampSource.next()
    let destination = fileStore.makePreviewDestination(
      deviceID: entry.device.id,
      capturedAt: capturedAt,
      kind: .video
    )

    var warning: Error?
    do {
      if sessionHasEnded {
        try await exec.collectScreenrecord(session: entry.session, savingTo: destination)
      } else {
        warning = try await exec.stopScreenrecord(session: entry.session, savingTo: destination)
      }
    } catch {
      await entry.restoreTouches(using: adb)
      throw error
    }
    await entry.restoreTouches(using: adb)

    let asset = AVURLAsset(url: destination)
    let duration = try await asset.load(.duration)
    guard duration.seconds > 0 else { return (nil, warning) }

    let adb = adb
    let device = entry.device
    let densityTask = Task<CGFloat?, Never> {
      let density = try? await adb.exec().withTimeout(.seconds(3)).displayDensity(deviceID: device.id)
      return density.map { CGFloat($0) }
    }
    guard let media = try await Media.video(
      from: asset,
      url: destination,
      capturedAt: capturedAt,
      densityProvider: { await densityTask.value }
    ) else {
      return (nil, warning)
    }
    return (CaptureMedia(device: device, media: media), warning)
  }

  private func discard(_ entries: [Entry], endedDeviceIDs: Set<String> = []) async {
    let adb = adb
    let cleanupTask = Task.detached(priority: .utility) {
      await withTaskGroup(of: Void.self) { group in
        for entry in entries {
          group.addTask {
            let exec = await adb.exec()
            if endedDeviceIDs.contains(entry.device.id) {
              await exec.discardScreenrecord(session: entry.session)
            } else {
              await exec.cancelScreenrecord(session: entry.session)
            }
            await entry.restoreTouches(using: adb)
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
      await discard(operation.entries, endedDeviceIDs: Set(operation.endedDeviceErrors.keys))
      await history?.discardEmpty(operation.historyID)
      await coordinator.release(operation.lease)
      await operation.completion.resolve(.cancelled)
    }
    while !pendingOperationIDs.isEmpty || !cleanupOperationIDs.isEmpty {
      await Task.yield()
    }
  }
}
