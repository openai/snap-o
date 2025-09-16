@preconcurrency import AVKit
import CoreGraphics
import Foundation

actor CaptureService {
  private let adb: ADBService
  private let fileStore: FileStore

  private var preloadedTask: Task<[CaptureMedia], Error>?
  private var didLogPreloadStart = false

  init(adb: ADBService, fileStore: FileStore) {
    self.adb = adb
    self.fileStore = fileStore
  }

  func captureScreenshots(for devices: [Device]) async -> ([CaptureMedia], Error?) {
    await collectMedia(for: devices) { device in
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

  func startRecording(for deviceID: String) async throws -> RecordingSession {
    try await adb.exec().startScreenrecord(deviceID: deviceID)
  }

  func stopRecording(session: RecordingSession, device: Device) async throws -> CaptureMedia? {
    let destination = fileStore.makePreviewDestination(deviceID: device.id, kind: .video)
    try await adb.exec().stopScreenrecord(session: session, savingTo: destination)
    let asset = AVURLAsset(url: destination)

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

  func preloadScreenshots(for devices: [Device]) async {
    guard !didLogPreloadStart else { return }

    Perf.step(.appFirstSnapshot, "Preloading first screenshot")
    didLogPreloadStart = true

    let previousTask = preloadedTask
    preloadedTask = Task {
      var accumulated: [CaptureMedia] = []
      if let previousTask {
        accumulated = (try? await previousTask.value) ?? []
      }
      let (media, _) = await self.captureScreenshots(for: devices)
      accumulated.append(contentsOf: media)
      return accumulated
    }
  }

  func consumeAllPreloadedScreenshots() async -> [CaptureMedia] {
    guard let task = preloadedTask else { return [] }
    preloadedTask = nil
    do {
      let media = try await task.value
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
            return .success(try await action(device))
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
}
