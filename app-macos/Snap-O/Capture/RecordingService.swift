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
  private enum StopStatus {
    case recording
    case confirmed
    case unconfirmed
  }

  private struct CollectedRecording {
    let device: Device
    let media: CaptureMedia?
    let failure: String?
  }

  private struct Entry {
    let device: Device
    let session: any ScreenRecording
    let showTouchesOverride: ShowTouchesOverride
    var touchRestoration: Task<Void, Never>?
    var stopStatus: StopStatus = .recording
    var failure: String?

    func restoreTouches(using adb: ADBService) async {
      if let touchRestoration {
        await touchRestoration.value
      } else {
        await showTouchesOverride.restore(using: adb, timeout: .seconds(3))
      }
    }
  }

  private struct SessionMonitor {
    let session: any ScreenRecording
    let task: Task<Void, Never>
  }

  private struct Operation {
    var entries: [Entry]
    let lease: DeviceCaptureLease
    let completion: RecordingOperationCompletion
    var sessionMonitors: [SessionMonitor]
    let historyID: UUID?
  }

  typealias StartRecording = @Sendable (String, Bool) async throws -> any ScreenRecording
  private let startRecording: StartRecording
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
    history: CaptureHistoryRepository? = nil,
    startRecording: StartRecording? = nil
  ) {
    self.adb = adb
    self.startRecording = startRecording ?? { deviceID, bugReport in
      let session = try await adb.exec().startScreenrecord(deviceID: deviceID, bugReport: bugReport)
      return ADBScreenRecording(session: session, adb: adb)
    }
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
      for: options.recordsBugReport ? .bugReportRecording : .recording
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
      await sessionEnded(
        operationID: handle.id,
        entry: entry,
        stopStatus: .unconfirmed,
        message: "Recording ended because the device disconnected."
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

    await discard(operation.entries)
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
    let startRecording = startRecording
    var entries: [Entry] = []
    var encounteredError: Error?

    await withTaskGroup(of: (Device, ShowTouchesOverride, Result<any ScreenRecording, Error>).self) { group in
      for device in devices {
        group.addTask {
          let showTouchesOverride = await ShowTouchesOverride.apply(
            deviceID: device.id,
            enabled: options.showsTouches,
            using: adb,
            timeout: .seconds(3)
          )
          do {
            let session = try await startRecording(device.id, options.recordsBugReport)
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
    historyID: UUID?
  ) async -> ([CaptureMedia], Error?) {
    var media: [CaptureMedia] = []
    var failures: [String] = []

    await withTaskGroup(of: CollectedRecording.self) { group in
      for entry in entries {
        group.addTask { await self.collect(entry, historyID: historyID) }
      }
      for await result in group {
        if let capture = result.media { media.append(capture) }
        if let failure = result.failure {
          let message = "\(result.device.displayTitle): \(failure)"
          failures.append(message)
          if result.media == nil {
            await history?.recordFailure(deviceID: result.device.id, message: message, in: historyID)
          }
        }
      }
    }
    let error = failures.isEmpty ? nil : RecordingLifecycleError(errorDescription: failures.sorted().joined(separator: "\n"))
    return (media, error)
  }

  private func monitorSession(
    _ entry: Entry,
    operationID: UUID
  ) -> Task<Void, Never> {
    Task { [weak self] in
      let stopStatus: StopStatus
      let message: String
      do {
        try await entry.session.waitUntilStopped()
        stopStatus = .confirmed
        message = "Recording ended unexpectedly."
      } catch {
        stopStatus = .unconfirmed
        message = "Recording ended unexpectedly (\(error.localizedDescription))."
      }
      guard !Task.isCancelled else { return }
      await self?.sessionEnded(operationID: operationID, entry: entry, stopStatus: stopStatus, message: message)
    }
  }

  private func sessionEnded(
    operationID: UUID,
    entry: Entry,
    stopStatus: StopStatus,
    message: String
  ) async {
    guard var operation = operations[operationID],
          let index = operation.entries.firstIndex(where: { $0.device.id == entry.device.id }),
          operation.entries[index].stopStatus == .recording else { return }
    let restoration = Task { await entry.showTouchesOverride.restore(using: adb, timeout: .seconds(3)) }
    operation.entries[index].touchRestoration = restoration
    operation.entries[index].stopStatus = stopStatus
    operation.entries[index].failure = message
    operations[operationID] = operation
    // Record an unconfirmed stop before closing the stream can wake its monitor.
    await entry.session.close()
    await restoration.value
    guard let current = operations[operationID] else { return }
    await history?.recordFailure(
      deviceID: entry.device.id, message: "\(entry.device.displayTitle): \(message)", in: current.historyID
    )

    // Keep Stop available until every device has ended or the user finishes the group.
    if current.entries.allSatisfy({ $0.stopStatus != .recording }) {
      await complete(operationID, endedSession: entry.session)
    }
  }

  private func complete(
    _ operationID: UUID,
    endedSession: (any ScreenRecording)? = nil
  ) async {
    guard let operation = takeOperation(
      operationID,
      preservingMonitorFor: endedSession
    ) else { return }
    cleanupOperationIDs.insert(operationID)
    defer { cleanupOperationIDs.remove(operationID) }

    let (media, captureError) = await collectMedia(
      from: operation.entries,
      historyID: operation.historyID
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
    preservingMonitorFor session: (any ScreenRecording)? = nil
  ) -> Operation? {
    guard let operation = operations.removeValue(forKey: operationID) else { return nil }
    for monitor in operation.sessionMonitors where monitor.session.id != session?.id {
      monitor.task.cancel()
    }
    return operation
  }

  private func stopIfRecording(_ entry: Entry) async -> Entry {
    guard entry.stopStatus == .recording else { return entry }
    var stopped = entry
    do {
      try await entry.session.stop()
      stopped.stopStatus = .confirmed
    } catch {
      stopped.stopStatus = .unconfirmed
      stopped.failure = error.localizedDescription
    }
    return stopped
  }

  private func collect(_ entry: Entry, historyID: UUID?) async -> CollectedRecording {
    let stopped = await stopIfRecording(entry)
    await stopped.restoreTouches(using: adb)
    let capturedAt = await timestampSource.next()
    let destination = fileStore.makePreviewDestination(deviceID: entry.device.id, capturedAt: capturedAt, kind: .video)

    do {
      try Task.checkCancellation()
      try await entry.session.save(to: destination)
      let capture = try await loadRecording(at: destination, device: entry.device, capturedAt: capturedAt)
      let retained = await history?.record(capture, in: historyID) ?? capture
      // Delete only after a confirmed stop and a usable local copy. Recovery keeps the device copy.
      if stopped.stopStatus == .confirmed {
        await entry.session.remove()
      }
      await entry.session.close()
      return CollectedRecording(device: entry.device, media: retained, failure: stopped.failure)
    } catch {
      try? FileManager.default.removeItem(at: destination)
      let message = [stopped.failure, error.localizedDescription].compactMap(\.self).joined(separator: "\n")
      await entry.session.close()
      return CollectedRecording(device: entry.device, media: nil, failure: message)
    }
  }

  private func loadRecording(at url: URL, device: Device, capturedAt: Date) async throws -> CaptureMedia {
    let invalidRecording = RecordingLifecycleError(errorDescription: "No playable recording was received.")
    let asset = AVURLAsset(url: url)
    let (duration, isPlayable) = try await asset.load(.duration, .isPlayable)
    guard isPlayable, duration.seconds > 0 else { throw invalidRecording }
    let adb = adb
    guard let media = try await Media.video(
      from: asset,
      url: url,
      capturedAt: capturedAt,
      densityProvider: {
        let density = try? await adb.exec().withTimeout(.seconds(3)).displayDensity(deviceID: device.id)
        return density.map { CGFloat($0) }
      }
    ) else { throw invalidRecording }
    return CaptureMedia(device: device, media: media)
  }

  private func discard(_ entries: [Entry]) async {
    let cleanupTask = Task.detached(priority: .utility) {
      await withTaskGroup(of: Void.self) { group in
        for entry in entries {
          group.addTask {
            let stopped = await self.stopIfRecording(entry)
            // Explicit discard removes the device copy even when stopping could not be confirmed.
            await entry.session.remove()
            await entry.session.close()
            await stopped.restoreTouches(using: self.adb)
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
      await history?.discardEmpty(operation.historyID)
      await coordinator.release(operation.lease)
      await operation.completion.resolve(.cancelled)
    }
    while !pendingOperationIDs.isEmpty || !cleanupOperationIDs.isEmpty {
      await Task.yield()
    }
  }
}
