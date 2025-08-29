@preconcurrency import AVKit
import CoreGraphics
import Foundation

actor CaptureService {
  private let adb: ADBClient
  private let fileStore: FileStore

  init(adb: ADBClient, fileStore: FileStore) {
    self.adb = adb
    self.fileStore = fileStore
  }

  func captureScreenshot(for deviceID: String) async throws -> Media {
    let data = try await adb.screencapPNG(deviceID: deviceID)
    let capturedAt = Date()
    let destination = fileStore.makePreviewDestination(deviceID: deviceID, kind: .image)

    async let writeAndSize: CGSize = Task.detached(priority: .utility) {
      try data.write(to: destination, options: [.atomic])
      return try pngSize(from: data)
    }.value
    async let densityTask = adb.screenDensityScale(deviceID: deviceID)

    let size = try await writeAndSize
    let density: CGFloat?
    do {
      density = try await densityTask
    } catch {
      density = nil
    }

    return .image(
      url: destination,
      capturedAt: capturedAt,
      size: size,
      densityScale: density
    )
  }

  func startRecording(for deviceID: String) async throws -> RecordingSession {
    try await adb.startScreenrecord(deviceID: deviceID)
  }

  func stopRecording(session: RecordingSession, deviceID: String) async throws -> Media? {
    let destination = fileStore.makePreviewDestination(deviceID: deviceID, kind: .video)
    try await adb.stopScreenrecord(session: session, savingTo: destination)
    let asset = AVURLAsset(url: destination)

    let densityTask = Task<CGFloat?, Never> { [adb, deviceID] in
      try? await adb.screenDensityScale(deviceID: deviceID)
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
}
