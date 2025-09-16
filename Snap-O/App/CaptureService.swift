@preconcurrency import AVKit
import CoreGraphics
import Foundation

actor CaptureService {
  private let adb: ADBService
  private let fileStore: FileStore

  private var preloadedScreenshots: [String: Task<CaptureMedia, Error>] = [:]
  private var didLogPreloadStart = false

  init(adb: ADBService, fileStore: FileStore) {
    self.adb = adb
    self.fileStore = fileStore
  }

  func captureScreenshot(for device: Device) async throws -> CaptureMedia {
    // Build a stateless exec from config for parallel commands.
    let exec = await adb.exec()

    async let dataTask: Data = try await exec.screencapPNG(deviceID: device.id)
    async let densityAsync: CGFloat? = await (try? exec.displayDensity(deviceID: device.id))
    let data = try await dataTask
    let capturedAt = Date()

    let destination = fileStore.makePreviewDestination(deviceID: device.id, kind: .image)
    let writeTask = Task(priority: .utility) { () throws -> CGSize in
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
    let captureMedia = CaptureMedia(deviceID: device.id, device: device, media: media)
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
      return CaptureMedia(deviceID: device.id, device: device, media: media)
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
    guard !devices.isEmpty else { return }

    if !didLogPreloadStart {
      Perf.step(.appFirstSnapshot, "Preloading first screenshot")
      didLogPreloadStart = true
    }

    for device in devices {
      if preloadedScreenshots[device.id] == nil {
        preloadedScreenshots[device.id] = Task {
          try await self.captureScreenshot(for: device)
        }
      }
    }
  }

  func consumeAllPreloadedScreenshots() async -> [CaptureMedia] {
    let deviceIDs = Array(preloadedScreenshots.keys)
    var results: [CaptureMedia] = []
    for id in deviceIDs {
      if let media = await consumePreloadedScreenshot(for: id) {
        results.append(media)
      }
    }
    return results
  }

  private func consumePreloadedScreenshot(for deviceID: String) async -> CaptureMedia? {
    guard let task = preloadedScreenshots.removeValue(forKey: deviceID) else {
      return nil
    }

    do {
      let media = try await task.value
      guard Date().timeIntervalSince(media.media.capturedAt) <= 1 else {
        return nil
      }
      Perf.step(.appFirstSnapshot, "return media")
      return media
    } catch {
      return nil
    }
  }
}
