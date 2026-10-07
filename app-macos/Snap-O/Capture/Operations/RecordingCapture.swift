@preconcurrency import AVKit
import CoreGraphics
import Dependencies
import Foundation
import Observation

private struct RecordingLifecycleError: LocalizedError {
  let errorDescription: String?
}

@Observable
@MainActor
final class RecordingCapture: CaptureBatch {
  @Dependency(\.videoFiles)
  @ObservationIgnored private var videoFiles
  private enum StopStatus {
    case recording
    case confirmed
    case unconfirmed
  }

  private final class Entry {
    let item: CaptureItem
    let session: any ScreenRecording
    let lease: DeviceCaptureLease
    let showTouchesOverride: ShowTouchesOverride
    var stopStatus: StopStatus = .recording
    var failure: String?
    var monitor: Task<Void, Never>?
    var endedCleanup: Task<Void, Never>?
    var finalization: Task<Void, Never>?

    init(item: CaptureItem, session: any ScreenRecording, lease: DeviceCaptureLease, showTouchesOverride: ShowTouchesOverride) {
      self.item = item
      self.session = session
      self.lease = lease
      self.showTouchesOverride = showTouchesOverride
    }
  }

  enum Phase { case starting, recording, finishing, cancelling }

  typealias StartRecording = @Sendable (Device, Bool) async throws -> any ScreenRecording
  typealias LoadRecording = @Sendable (URL, Device, Date) async throws -> CaptureMedia

  let id = UUID()
  let items: [CaptureItem]
  let kind: CaptureKind = .recording
  private(set) var phase: Phase = .starting
  private(set) var isComplete = false
  let options: RecordingOptions
  private let adb: ADBService
  private let fileStore: FileStore
  private let coordinator: CaptureCoordinator
  private let startRecording: StartRecording
  private let recordingLoader: LoadRecording?
  private let timestampSource: CaptureTimestampSource
  private var invalidationHandlers: [DeviceTarget: UUID] = [:]
  private var entries: [Entry] = []
  private var startupErrors: [UUID: Error] = [:]
  @ObservationIgnored private(set) var startup: Task<Error?, Never>?
  @ObservationIgnored private var finalization: Task<Void, Never>?
  @ObservationIgnored private var closeTask: Task<Void, Never>?

  init(
    devices: [Device], options: RecordingOptions,
    adb: ADBService, fileStore: FileStore, coordinator: CaptureCoordinator,
    startRecording: @escaping StartRecording, loadRecording: LoadRecording?,
    timestampSource: CaptureTimestampSource
  ) {
    items = devices.map(CaptureItem.init)
    self.options = options
    self.adb = adb
    self.fileStore = fileStore
    self.coordinator = coordinator
    self.startRecording = startRecording
    recordingLoader = loadRecording
    self.timestampSource = timestampSource
    for device in devices {
      guard let target = device.connection else { continue }
      if let handler = try? target.onInvalidation({ [weak self] in
        Task { @MainActor in self?.connectionLost(target) }
      }) {
        invalidationHandlers[target] = handler
      }
    }
  }

  func start() {
    guard phase == .starting, startup == nil, !isComplete else { return }
    startup = Task { await startReserved() }
  }

  private func startReserved() async -> Error? {
    let adb = adb
    let options = options
    let startRecording = startRecording
    let coordinator = coordinator
    await withTaskGroup(of: (UUID, ShowTouchesOverride?, DeviceCaptureLease?, Result<any ScreenRecording, Error>).self) { group in
      for item in items {
        let id = item.id
        let device = item.device
        group.addTask {
          var lease: DeviceCaptureLease?
          var touches: ShowTouchesOverride?
          do {
            try Task.checkCancellation()
            let target = try device.requireConnection()
            lease = try await coordinator.acquire(
              target: target, for: options.recordsBugReport ? .bugReportRecording : .recording
            )
            touches = await ShowTouchesOverride.apply(target: target, enabled: options.showsTouches, using: adb)
            try Task.checkCancellation()
            let session = try await startRecording(device, options.recordsBugReport)
            return (id, touches, lease, .success(session))
          } catch {
            await touches?.restore(using: adb)
            if let lease { await coordinator.release(lease) }
            return (id, nil, nil, .failure(error))
          }
        }
      }
      for await (id, touches, lease, result) in group {
        guard let item = items.first(where: { $0.id == id }) else { continue }
        switch result {
        case .success(let session):
          guard let touches, let lease else { preconditionFailure("Started recording must own its resources") }
          let entry = Entry(item: item, session: session, lease: lease, showTouchesOverride: touches)
          entries.append(entry)
          if item.target?.isValid != true {
            let error = RecordingLifecycleError(errorDescription: "The device disconnected while recording was starting.")
            failStartup(item, error: error)
            finish(entry, discarding: true)
          } else if phase == .cancelling || Task.isCancelled {
            finish(entry, discarding: true)
          } else if phase == .finishing {
            finish(entry, discarding: false)
          } else {
            item.update(.recording)
            phase = .recording
            entry.monitor = monitor(entry)
          }
        case .failure(let error):
          failStartup(item, error: error)
        }
      }
    }
    if !entries.contains(where: { $0.finalization == nil && $0.stopStatus == .recording }) {
      beginFinalization(discarding: phase == .cancelling)
    }
    let didStart = entries.contains { startupErrors[$0.item.id] == nil }
    return didStart ? nil : startupErrors.values.first
  }

  private func failStartup(_ item: CaptureItem, error: Error) {
    startupErrors[item.id] = error
    item.update(error is CancellationError ? .cancelled : .failed(error.localizedDescription))
  }

  func requestFinish() {
    beginFinalization(discarding: false)
  }

  @discardableResult
  func beginFinalization(discarding: Bool) -> Task<Void, Never> {
    if let finalization { return finalization }
    phase = discarding ? .cancelling : .finishing
    if discarding { startup?.cancel() }
    // Stop acquired sessions now. A different device may still be starting.
    for entry in entries {
      finish(entry, discarding: discarding)
    }
    let task = Task {
      _ = await startup?.value
      for entry in entries {
        await finish(entry, discarding: discarding).value
      }
      for item in items {
        if case .pending = item.state { item.update(.cancelled) }
      }
      for (target, handler) in invalidationHandlers {
        target.removeInvalidationHandler(handler)
      }
      invalidationHandlers.removeAll()
      isComplete = true
    }
    finalization = task
    return task
  }

  func close() async {
    if let closeTask { await closeTask.value
      return
    }
    let completion = beginFinalization(discarding: true)
    let task = Task {
      await completion.value
      fileStore.discardPreviews(items.compactMap(\.media))
    }
    closeTask = task
    await task.value
  }

  private func connectionLost(_ target: DeviceTarget) {
    guard let entry = entries.first(where: { $0.item.target == target }) else { return }
    sessionEnded(entry, status: .unconfirmed, message: "Recording ended because the device disconnected.")
  }

  private func monitor(_ entry: Entry) -> Task<Void, Never> {
    Task { [weak self] in
      let status: StopStatus
      let message: String
      do {
        try await entry.session.waitUntilStopped()
        status = .confirmed
        message = "Recording ended unexpectedly."
      } catch {
        status = .unconfirmed
        message = "Recording ended unexpectedly (\(error.localizedDescription))."
      }
      guard !Task.isCancelled else { return }
      self?.sessionEnded(entry, status: status, message: message)
    }
  }

  private func sessionEnded(_ entry: Entry, status: StopStatus, message: String) {
    guard entry.finalization == nil, entry.stopStatus == .recording else { return }
    entry.stopStatus = status
    entry.failure = message
    entry.item.update(.failed(message))
    let touches = entry.showTouchesOverride
    entry.endedCleanup = Task {
      async let restoration: Void = touches.restore(using: adb)
      await entry.session.close()
      await restoration
    }
    // Pending devices must get their own chance to start.
    if !items.contains(where: { if case .pending = $0.state { return true }
      return false
    }),
      entries.allSatisfy({ $0.stopStatus != .recording }) {
      requestFinish()
    }
  }

  @discardableResult
  private func finish(_ entry: Entry, discarding: Bool) -> Task<Void, Never> {
    if let finalization = entry.finalization { return finalization }
    entry.monitor?.cancel()
    let task = Task {
      await entry.endedCleanup?.value
      if entry.stopStatus == .recording {
        do {
          try await entry.session.stop()
          entry.stopStatus = .confirmed
        } catch {
          entry.stopStatus = .unconfirmed
          entry.failure = error.localizedDescription
        }
      }
      await entry.showTouchesOverride.restore(using: adb)
      if discarding {
        await entry.session.remove()
        await entry.session.close()
        if startupErrors[entry.item.id] == nil { entry.item.update(.cancelled) }
      } else {
        entry.item.update(.collecting)
        await collect(entry)
      }
      await entry.monitor?.value
      coordinator.release(entry.lease)
    }
    entry.finalization = task
    return task
  }

  private func collect(_ entry: Entry) async {
    let device = entry.item.device
    let capturedAt = await timestampSource.next()
    let destination = fileStore.makePreviewDestination(deviceID: device.id, capturedAt: capturedAt, kind: .video)
    do {
      try await entry.session.save(to: destination)
      let capture = try await loadRecording(at: destination, device: device, capturedAt: capturedAt)
      // Preserve the remote copy unless stop was confirmed and the local copy is usable.
      if entry.stopStatus == .confirmed { await entry.session.remove() }
      await entry.session.close()
      entry.item.update(.ready(capture, warning: entry.failure))
    } catch {
      fileStore.discardTemporaryFile(at: destination)
      let message = [entry.failure, error.localizedDescription].compactMap(\.self).joined(separator: "\n")
      entry.failure = message
      await entry.session.close()
      entry.item.update(.failed(message))
    }
  }

  private func loadRecording(at url: URL, device: Device, capturedAt: Date) async throws -> CaptureMedia {
    if let recordingLoader { return try await recordingLoader(url, device, capturedAt) }
    let invalidRecording = RecordingLifecycleError(errorDescription: "No playable recording was received.")
    let info = try await videoFiles.inspect(url)
    guard info.isPlayable, info.duration > 0 else { throw invalidRecording }
    var density: CGFloat?
    if let target = try? device.requireConnection() {
      let value = try? await adb.exec().bound(to: target).withTimeout(.seconds(3)).displayDensity(deviceID: device.serial)
      density = value.map { CGFloat($0) }
    }
    return CaptureMedia(device: device, media: .video(
      url: url,
      capturedAt: capturedAt,
      display: DisplayInfo(size: info.displayedSize, densityScale: density)
    ))
  }
}
