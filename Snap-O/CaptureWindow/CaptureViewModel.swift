import AppKit
@preconcurrency import AVKit
import Observation

private let log = SnapOLog.ui

@MainActor
@Observable
final class CaptureViewModel {
  var currentMedia: Media?
  var isLoading = false
  var isRecording = false
  var recordingDeviceID: String?
  var recordingHandle: RecordingHandle?
  var lastError: String?
  var pendingCommand: SnapOCommand?

  private let adb: ADBClient
  private let store: FileStore
  private let recordingService: RecordingService

  init(adb: ADBClient, store: FileStore, recordingService: RecordingService) {
    self.adb = adb
    self.store = store
    self.recordingService = recordingService
  }

  // MARK: - Convenience State

  var canCapture: Bool { !isLoading && !isRecording }
  var canStartRecording: Bool { !isLoading && !isRecording }
  var canStopRecording: Bool { isRecording }

  func copy() {
    guard let media = currentMedia, media.kind == .image else { return }
    guard let image = NSImage(contentsOf: media.url) else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.writeObjects([image])
  }

  // Screenshot
  func refreshPreview(for deviceID: String) async {
    guard !isLoading, !isRecording else { return }
    currentMedia = nil
    if pendingCommand == .record {
      pendingCommand = nil
      await startRecording(for: deviceID)
      return
    }
    pendingCommand = nil
    isLoading = true
    defer { isLoading = false }
    do {
      let data = try await adb.screencapPNG(deviceID: deviceID)
      let capturedAt = Date()
      let dest = store.makePreviewDestination(deviceID: deviceID, kind: MediaKind.image)

      async let writeAndSize: (Int, Int) = Task.detached(priority: .utility) {
        try data.write(to: dest, options: [.atomic])
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

      currentMedia = Media(
        kind: .image,
        url: dest,
        capturedAt: capturedAt,
        width: CGFloat(size.0),
        height: CGFloat(size.1),
        densityScale: density
      )
      lastError = nil
    } catch {
      currentMedia = nil
      lastError = error.localizedDescription
    }
  }

  func makeTempDragFile() -> URL? {
    guard let media = currentMedia else { return nil }

    do {
      let url = store.makeDragDestination(capturedAt: media.capturedAt, kind: media.kind)
      try FileManager.default.copyItem(at: media.url, to: url)
      return url
    } catch {
      log.error("Drag temp copy failed: \(error.localizedDescription)")
      return nil
    }
  }

  // Recording
  func startRecording(for deviceID: String) async {
    guard !isLoading, !isRecording else { return }
    currentMedia = nil
    isLoading = true
    defer { isLoading = false }
    do {
      let handle = try await recordingService.start(deviceID: deviceID)
      isRecording = true
      recordingDeviceID = deviceID
      recordingHandle = handle
      lastError = nil
    } catch {
      lastError = error.localizedDescription
    }
  }

  func stopRecording() async {
    guard isRecording, let deviceID = recordingDeviceID, let handle = recordingHandle else { return }
    isRecording = false
    recordingDeviceID = nil
    recordingHandle = nil
    isLoading = true
    defer { isLoading = false }
    do {
      let dest = store.makePreviewDestination(deviceID: deviceID, kind: MediaKind.video)
      try await recordingService.stop(handle: handle, savingTo: dest)
      let asset = AVURLAsset(url: dest)

      async let tracksTask = asset.load(.tracks)
      async let densityTask = adb.screenDensityScale(deviceID: deviceID)

      let tracks = try await tracksTask
      if let videoTrack = tracks.first(where: { $0.mediaType == .video }) {
        async let naturalSizeTask = videoTrack.load(.naturalSize)
        async let transformTask = videoTrack.load(.preferredTransform)
        let (naturalSize, transform) = try await (naturalSizeTask, transformTask)
        let applied = naturalSize.applying(transform)
        let w = abs(applied.width)
        let h = abs(applied.height)

        let density: CGFloat?
        do {
          density = try await densityTask
        } catch {
          density = nil
        }

        currentMedia = Media(
          kind: .video,
          url: dest,
          capturedAt: Date(),
          width: w,
          height: h,
          densityScale: density
        )
      }
      lastError = nil
    } catch {
      lastError = error.localizedDescription
    }
  }
}

/// Read PNG pixel size using ImageIO (no NSImage necessary).
private func pngSize(from data: Data) throws -> (Int, Int) {
  guard let source = CGImageSourceCreateWithData(data as CFData, nil),
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
        let width = properties[kCGImagePropertyPixelWidth] as? Int,
        let height = properties[kCGImagePropertyPixelHeight] as? Int
  else {
    throw CocoaError(.fileReadCorruptFile)
  }
  return (width, height)
}
