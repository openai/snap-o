@preconcurrency import AVKit
import CoreGraphics
import Foundation

actor CaptureService {
  private let adb: ADBService
  private let fileStore: FileStore

  private var preloadedScreenshotTask: Task<Media, Error>?
  private var preloadedScreenshotDeviceID: String?

  init(adb: ADBService, fileStore: FileStore) {
    self.adb = adb
    self.fileStore = fileStore
  }

  func captureScreenshot(for deviceID: String) async throws -> Media {
    // Build a stateless exec from config for parallel commands.
    let exec = await adb.exec()

    async let dataTask: Data = try await exec.screencapPNG(deviceID: deviceID)
    async let densityAsync: CGFloat? = await (try? exec.screenDensityScale(deviceID: deviceID))
    let data = try await dataTask
    let capturedAt = Date()

    let destination = fileStore.makePreviewDestination(deviceID: deviceID, kind: .image)
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
    return media
  }

  func startRecording(for deviceID: String) async throws -> RecordingSession {
    try await adb.exec().startScreenrecord(deviceID: deviceID)
  }

  func stopRecording(session: RecordingSession, deviceID: String) async throws -> Media? {
    let destination = fileStore.makePreviewDestination(deviceID: deviceID, kind: .video)
    try await adb.exec().stopScreenrecord(session: session, savingTo: destination)
    let asset = AVURLAsset(url: destination)

    let densityTask = Task<CGFloat?, Never> { [adb, deviceID] in
      try? await adb.exec().screenDensityScale(deviceID: deviceID)
    }

    if let media = try await Media.video(
      from: asset,
      url: destination,
      capturedAt: Date(),
      densityProvider: { await densityTask.value }
    ) {
      return media
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

  func preloadScreenshot(for deviceID: String) async {
    guard preloadedScreenshotTask == nil else { return }

    preloadedScreenshotDeviceID = deviceID
    preloadedScreenshotTask = Task {
      Perf.step(.appFirstSnapshot, "Preloading first screenshot")
      return try await self.captureScreenshot(for: deviceID)
    }
  }

  func consumePreloadedScreenshot(for deviceID: String) async -> Media? {
    guard preloadedScreenshotDeviceID == deviceID,
          let task = preloadedScreenshotTask else {
      return nil
    }

    preloadedScreenshotTask = nil
    preloadedScreenshotDeviceID = nil

    do {
      let media = try await task.value
      guard Date().timeIntervalSince(media.capturedAt) <= 1 else {
        return nil
      }
      Perf.step(.appFirstSnapshot, "return media")
      return media
    } catch {
      return nil
    }
  }
}
