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
final class RecordingCapture: CaptureOperation {
  @Dependency(\.videoFiles)
  @ObservationIgnored private var videoFiles
  private enum StopStatus {
    case recording
    case confirmed
    case unconfirmed
  }

  private final class Entry {
    let session: any ScreenRecording
    let lease: DeviceCaptureLease
    let showTouchesOverride: ShowTouchesOverride
    var stopStatus: StopStatus = .recording
    var failure: String?
    var monitor: Task<Void, Never>?
    var endedCleanup: Task<Void, Never>?
    var finalization: Task<Void, Never>?

    init(session: any ScreenRecording, lease: DeviceCaptureLease, showTouchesOverride: ShowTouchesOverride) {
      self.session = session
      self.lease = lease
      self.showTouchesOverride = showTouchesOverride
    }
  }

  enum Phase { case starting, recording, finishing, cancelling }

  typealias StartRecording = @Sendable (Device, Bool) async throws -> any ScreenRecording
  typealias LoadRecording = @Sendable (URL, Device, Date) async throws -> CaptureMedia

  let id = UUID()
  let device: Device
  private(set) var state: CaptureState = .pending
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
  private var invalidationHandler: UUID?
  private var entry: Entry?
  private var startupError: Error?
  @ObservationIgnored private(set) var startup: Task<Error?, Never>?
  @ObservationIgnored private var finalization: Task<Void, Never>?
  @ObservationIgnored private var closeTask: Task<Void, Never>?

  init(
    device: Device, options: RecordingOptions,
    adb: ADBService, fileStore: FileStore, coordinator: CaptureCoordinator,
    startRecording: @escaping StartRecording, loadRecording: LoadRecording?,
    timestampSource: CaptureTimestampSource
  ) {
    self.device = device
    self.options = options
    self.adb = adb
    self.fileStore = fileStore
    self.coordinator = coordinator
    self.startRecording = startRecording
    recordingLoader = loadRecording
    self.timestampSource = timestampSource
    if let target = device.connection {
      invalidationHandler = try? target.onInvalidation { [weak self] in
        Task { @MainActor in self?.connectionLost() }
      }
    }
  }

  func start() {
    guard phase == .starting, startup == nil, !isComplete else { return }
    startup = Task { await startReserved() }
  }

  private func startReserved() async -> Error? {
    var lease: DeviceCaptureLease?
    var touches: ShowTouchesOverride?
    do {
      try Task.checkCancellation()
      let target = try device.requireConnection()
      lease = try coordinator.acquire(target: target, for: options.recordsBugReport ? .bugReportRecording : .recording)
      touches = await ShowTouchesOverride.apply(target: target, enabled: options.showsTouches, using: adb)
      try Task.checkCancellation()
      let session = try await startRecording(device, options.recordsBugReport)
      guard let touches, let lease else { preconditionFailure("Started recording must own its resources") }
      let entry = Entry(session: session, lease: lease, showTouchesOverride: touches)
      self.entry = entry
      if !target.isValid {
        let error = RecordingLifecycleError(errorDescription: "The device disconnected while recording was starting.")
        failStartup(error)
        finish(entry, discarding: true)
      } else if phase == .cancelling || Task.isCancelled {
        finish(entry, discarding: true)
      } else if phase == .finishing {
        finish(entry, discarding: false)
      } else {
        state = .recording
        phase = .recording
        entry.monitor = monitor(entry)
      }
    } catch {
      await touches?.restore(using: adb)
      if let lease { coordinator.release(lease) }
      failStartup(error)
    }
    if entry?.finalization != nil || entry == nil {
      beginFinalization(discarding: phase == .cancelling)
    }
    return startupError
  }

  private func failStartup(_ error: Error) {
    startupError = error
    state = error is CancellationError ? .cancelled : .failed(error.localizedDescription)
  }

  func requestFinish() {
    beginFinalization(discarding: false)
  }

  @discardableResult
  func beginFinalization(discarding: Bool) -> Task<Void, Never> {
    if let finalization { return finalization }
    phase = discarding ? .cancelling : .finishing
    if discarding { startup?.cancel() }
    // Stop an acquired session immediately, including while startup is finishing.
    if let entry {
      finish(entry, discarding: discarding)
    }
    let task = Task {
      _ = await startup?.value
      if let entry {
        await finish(entry, discarding: discarding).value
      }
      if case .pending = state { state = .cancelled }
      if let invalidationHandler { device.connection?.removeInvalidationHandler(invalidationHandler) }
      invalidationHandler = nil
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
      if let media { fileStore.discardPreviews([media]) }
    }
    closeTask = task
    await task.value
  }

  private func connectionLost() {
    guard let entry else { return }
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
    state = .failed(message)
    let touches = entry.showTouchesOverride
    entry.endedCleanup = Task {
      async let restoration: Void = touches.restore(using: adb)
      await entry.session.close()
      await restoration
    }
    requestFinish()
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
        if startupError == nil { state = .cancelled }
      } else {
        state = .collecting
        await collect(entry)
      }
      await entry.monitor?.value
      coordinator.release(entry.lease)
    }
    entry.finalization = task
    return task
  }

  private func collect(_ entry: Entry) async {
    let capturedAt = await timestampSource.next()
    let destination = fileStore.makePreviewDestination(deviceID: device.id, capturedAt: capturedAt, kind: .video)
    do {
      try await entry.session.save(to: destination)
      let capture = try await loadRecording(at: destination, device: device, capturedAt: capturedAt)
      // Preserve the remote copy unless stop was confirmed and the local copy is usable.
      if entry.stopStatus == .confirmed { await entry.session.remove() }
      await entry.session.close()
      state = .ready(capture, warning: entry.failure)
    } catch {
      fileStore.discardTemporaryFile(at: destination)
      let message = [entry.failure, error.localizedDescription].compactMap(\.self).joined(separator: "\n")
      entry.failure = message
      await entry.session.close()
      state = .failed(message)
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
