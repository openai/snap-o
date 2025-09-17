@preconcurrency import AVKit
import CoreGraphics
import Foundation

actor CaptureService {
  private let adb: ADBService
  private let fileStore: FileStore
  private let deviceTracker: DeviceTracker

  private var preloadedTask: Task<([CaptureMedia], Error?), Error>?
  private var didLogPreloadStart = false

  init(adb: ADBService, fileStore: FileStore, deviceTracker: DeviceTracker) {
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
    let capturedAt = Date()

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

    await withTaskGroup(of: (String, Result<RecordingSession, Error>).self) { group in
      for device in devices {
        group.addTask {
          do {
            let session = try await self.adb.exec().startScreenrecord(deviceID: device.id)
            return (device.id, .success(session))
          } catch {
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
    let destination = fileStore.makePreviewDestination(deviceID: device.id, kind: .video)
    try await adb.exec().stopScreenrecord(session: session, savingTo: destination)
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
      capturedAt: Date(),
      densityProvider: { await densityTask.value }
    ) {
      return CaptureMedia(device: device, media: media)
    }
    return nil
  }

  func startLivePreview(for deviceID: String) async throws -> LivePreviewSession {
    try await LivePreviewSession(deviceID: deviceID, adb: adb)
  }

  func stopLivePreview(session: LivePreviewSession) async -> Error? {
    await session.cancel()
    return await session.waitUntilStop()
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

  private func collectMedia(
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

  private func collectOptionalMedia(
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
