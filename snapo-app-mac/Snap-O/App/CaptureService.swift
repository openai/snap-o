@preconcurrency import AVKit
import CoreGraphics
import Foundation

actor CaptureService {
  private let adb: ADBService
  private let fileStore: FileStore
  private let deviceTracker: DeviceTracker

  private var preloadedTask: Task<([CaptureMedia], Error?), Error>?
  private var didLogPreloadStart = false
  private var lastCaptureTimestamp: Date? // Keeps filenames unique when captures share a real timestamp.
  private var showTouchesOverrides: [String: Task<Bool?, Never>] = [:]

  init(
    adb: ADBService,
    fileStore: FileStore,
    deviceTracker: DeviceTracker
  ) {
    self.adb = adb
    self.fileStore = fileStore
    self.deviceTracker = deviceTracker
  }

  func captureScreenshots() async -> ([CaptureMedia], Error?) {
    await collectMedia(for: deviceTracker.latestDevices) { device in
      try await self.captureScreenshot(for: device)
    }
  }

  private func captureScreenshot(for device: Device) async throws -> CaptureMedia {
    // Build a stateless exec from config for parallel commands.
    let exec = await adb.exec()

    async let dataTask: Data = try await exec.screencapPNG(deviceID: device.id)
    async let densityAsync: CGFloat? = await (try? exec.displayDensity(deviceID: device.id))
    let data = try await dataTask
    let capturedAt = nextCaptureTimestamp(basedOn: Date())

    let destination = fileStore.makePreviewDestination(deviceID: device.id, kind: .image)
    let writeTask = Task(priority: .userInitiated) { () throws -> CGSize in
      try data.write(to: destination, options: [.atomic])
      return try pngSize(from: data)
    }

    let size = try await writeTask.value
    let density = await densityAsync
    let display = DisplayInfo(size: size, densityScale: density)

    let media: Media = .image(
      url: destination,
      capturedAt: capturedAt,
      display: display
    )
    let captureMedia = CaptureMedia(device: device, media: media)
    return captureMedia
  }

  func startRecordings(for devices: [Device]) async -> ([String: RecordingSession], Error?) {
    var sessions: [String: RecordingSession] = [:]
    var encounteredError: Error?
    let targetBugReport = await AppSettings.shared.recordAsBugReport

    await withTaskGroup(of: (String, Result<RecordingSession, Error>).self) { group in
      let exec = await adb.exec()
      for device in devices {
        group.addTask {
          await self.beginShowTouchesOverride(deviceID: device.id)
          do {
            let session = try await exec.startScreenrecord(
              deviceID: device.id,
              bugReport: targetBugReport
            )
            return (device.id, .success(session))
          } catch {
            await self.scheduleRestoreShowTouches(deviceID: device.id)
            return (device.id, .failure(error))
          }
        }
      }

      for await (deviceID, result) in group {
        switch result {
        case .success(let session):
          sessions[deviceID] = session
        case .failure(let error):
          encounteredError = error
        }
      }
    }

    return (sessions, encounteredError)
  }

  func stopRecordings(
    for devices: [Device],
    sessions: [String: RecordingSession]
  ) async -> ([CaptureMedia], Error?) {
    await collectOptionalMedia(for: devices) { device in
      guard let session = sessions[device.id] else { return nil }
      return try await self.stopRecording(session: session, device: device)
    }
  }

  private func stopRecording(session: RecordingSession, device: Device) async throws -> CaptureMedia? {
    let exec = await adb.exec()
    let destination = fileStore.makePreviewDestination(deviceID: device.id, kind: .video)

    do {
      try await exec.stopScreenrecord(session: session, savingTo: destination)
    } catch {
      await scheduleRestoreShowTouches(deviceID: device.id)
      throw error
    }

    await scheduleRestoreShowTouches(deviceID: device.id)
    let asset = AVURLAsset(url: destination)
    let duration = try await asset.load(.duration)
    if duration.seconds <= 0 {
      return nil
    }

    let densityTask = Task<CGFloat?, Never> { [adb, device] in
      try? await adb.exec().displayDensity(deviceID: device.id)
    }

    if let media = try await Media.video(
      from: asset,
      url: destination,
      capturedAt: nextCaptureTimestamp(basedOn: Date()),
      densityProvider: { await densityTask.value }
    ) {
      return CaptureMedia(device: device, media: media)
    }
    return nil
  }

  private func nextCaptureTimestamp(basedOn proposed: Date) -> Date {
    guard let last = lastCaptureTimestamp else {
      lastCaptureTimestamp = proposed
      return proposed
    }

    let lastRounded = floor(last.timeIntervalSince1970)
    let proposedRounded = floor(proposed.timeIntervalSince1970)

    if proposedRounded <= lastRounded {
      let adjusted = Date(timeIntervalSince1970: lastRounded + 1)
      lastCaptureTimestamp = adjusted
      return adjusted
    }

    lastCaptureTimestamp = proposed
    return proposed
  }

  func startLivePreview(for deviceID: String) async throws -> LivePreviewSession {
    beginShowTouchesOverride(deviceID: deviceID)

    do {
      return try await LivePreviewSession(deviceID: deviceID, adb: adb)
    } catch {
      await scheduleRestoreShowTouches(deviceID: deviceID)
      throw error
    }
  }

  func stopLivePreview(session: LivePreviewSession) async -> Error? {
    await session.cancel()
    let stopError = await session.waitUntilStop()
    await scheduleRestoreShowTouches(deviceID: session.deviceID)

    return stopError
  }

  func preloadScreenshots() async {
    let devices = deviceTracker.latestDevices

    guard !didLogPreloadStart, !devices.isEmpty else {
      return
    }

    Perf.step(.appFirstSnapshot, "Preloading first screenshot")
    didLogPreloadStart = true

    preloadedTask = Task {
      await self.captureScreenshots()
    }
  }

  func consumeAllPreloadedScreenshots() async -> [CaptureMedia] {
    guard let task = preloadedTask else { return [] }
    preloadedTask = nil
    do {
      let (media, _) = try await task.value
      let fresh = media.filter { Date().timeIntervalSince($0.media.capturedAt) <= 1 }
      if fresh.isEmpty { return [] }
      Perf.step(.appFirstSnapshot, "return media")
      return fresh
    } catch {
      return []
    }
  }

  private func beginShowTouchesOverride(deviceID: String) {
    guard showTouchesOverrides[deviceID] == nil else { return }

    let task = Task<Bool?, Never> {
      let targetValue = await AppSettings.shared.showTouchesDuringCapture
      let exec = await adb.exec()
      do {
        let originalValue = try await exec.getShowTouches(deviceID: deviceID)
        if originalValue != targetValue {
          try await exec.setShowTouches(deviceID: deviceID, enabled: targetValue)
        }
        return originalValue
      } catch {
        SnapOLog.recording.error(
          """
          Failed to update show touches for \(deviceID, privacy: .private):
          \(error.localizedDescription, privacy: .public)
          """
        )
        return nil
      }
    }

    showTouchesOverrides[deviceID] = task
  }

  private func scheduleRestoreShowTouches(deviceID: String) async {
    guard let task = showTouchesOverrides.removeValue(forKey: deviceID) else { return }
    let exec = await adb.exec()
    Task.detached(priority: .utility) {
      let originalValue = await task.value
      guard let originalValue else { return }
      do {
        try await exec.setShowTouches(deviceID: deviceID, enabled: originalValue)
      } catch {
        SnapOLog.recording.error(
          """
          Failed to restore show touches for \(deviceID, privacy: .private):
          \(error.localizedDescription, privacy: .public)
          """
        )
      }
    }
  }
}

private extension CaptureService {
  func collectMedia(
    for devices: [Device],
    action: @escaping @Sendable (Device) async throws -> CaptureMedia
  ) async -> ([CaptureMedia], Error?) {
    var results: [CaptureMedia] = []
    var encounteredError: Error?

    await withTaskGroup(of: Result<CaptureMedia, Error>.self) { group in
      for device in devices {
        group.addTask {
          do {
            return try await .success(action(device))
          } catch {
            return .failure(error)
          }
        }
      }

      for await outcome in group {
        switch outcome {
        case .success(let media):
          results.append(media)
        case .failure(let error):
          encounteredError = error
        }
      }
    }

    return (results, encounteredError)
  }

  func collectOptionalMedia(
    for devices: [Device],
    action: @escaping @Sendable (Device) async throws -> CaptureMedia?
  ) async -> ([CaptureMedia], Error?) {
    var results: [CaptureMedia] = []
    var encounteredError: Error?

    await withTaskGroup(of: Result<CaptureMedia?, Error>.self) { group in
      for device in devices {
        group.addTask {
          do {
            return try await .success(action(device))
          } catch {
            return .failure(error)
          }
        }
      }

      for await outcome in group {
        switch outcome {
        case .success(let media?):
          results.append(media)
        case .success(nil):
          continue
        case .failure(let error):
          encounteredError = error
        }
      }
    }

    return (results, encounteredError)
  }
}
