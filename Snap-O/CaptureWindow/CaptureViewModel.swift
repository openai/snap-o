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
  var recordingSession: RecordingSession?
  var lastError: String?
  var pendingCommand: SnapOCommand?
  var livePreviewMedia: Media?
  var livePreviewSession: LivePreviewSession?

  private let adb: ADBClient
  private let store: FileStore
  private let settings: AppSettings

  private var showTouchesOriginalValue: Bool?
  private var showTouchesDeviceID: String?

  init(adb: ADBClient, store: FileStore, settings: AppSettings) {
    self.adb = adb
    self.store = store
    self.settings = settings
  }

  // MARK: - Convenience State

  var canCapture: Bool { !isLoading && !isRecording }
  var canStartRecording: Bool { !isLoading && !isRecording }
  var canStopRecording: Bool { isRecording }
  var isLivePreviewing: Bool { livePreviewSession != nil }
  var canStartLivePreview: Bool { !isLoading && !isRecording && livePreviewSession == nil }
  var canStopLivePreview: Bool { livePreviewSession != nil }
  var displayMedia: Media? { isLivePreviewing ? livePreviewMedia : currentMedia }

  func copy() {
    guard let media = currentMedia, media.kind == .image else { return }
    guard let image = NSImage(contentsOf: media.url) else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.writeObjects([image])
  }

  // Screenshot
  func refreshPreview(for deviceID: String) async {
    guard !isLoading, !isRecording else { return }
    if isLivePreviewing {
      stopLivePreview()
    }
    currentMedia = nil
    if pendingCommand == .record {
      pendingCommand = nil
      await startRecording(for: deviceID)
      return
    }
    if pendingCommand == .livepreview {
      pendingCommand = nil
      await startLivePreview(for: deviceID)
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
    if isLivePreviewing {
      stopLivePreview()
    }
    currentMedia = nil
    isLoading = true
    defer { isLoading = false }
    do {
      await storeOriginalShowTouches(for: deviceID)
      await updateShowTouches(for: deviceID)

      let session = try await adb.startScreenrecord(deviceID: deviceID)
      isRecording = true
      recordingDeviceID = deviceID
      recordingSession = session
      lastError = nil
    } catch {
      await restoreShowTouchesIfNeeded()
      lastError = error.localizedDescription
    }
  }

  func stopRecording() async {
    guard isRecording, let deviceID = recordingDeviceID, let session = recordingSession else { return }
    isRecording = false
    recordingDeviceID = nil
    recordingSession = nil
    isLoading = true
    defer { isLoading = false }
    do {
      let dest = store.makePreviewDestination(deviceID: deviceID, kind: MediaKind.video)
      try await adb.stopScreenrecord(session: session, savingTo: dest)
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
    await restoreShowTouchesIfNeeded()
  }

  // Live Preview
  func startLivePreview(for deviceID: String) async {
    guard !isLoading, !isRecording, livePreviewSession == nil else { return }
    currentMedia = nil
    livePreviewMedia = nil
    isLoading = true
    lastError = nil

    do {
      await storeOriginalShowTouches(for: deviceID)
      await updateShowTouches(for: deviceID)

      let session = try await LivePreviewSession(
        deviceID: deviceID,
        adb: adb,
        onReady: { [weak self] media in
          self?.livePreviewMedia = media
          self?.isLoading = false
        },
        onStop: { [weak self] error, refresh in
          self?.completeLivePreview(for: deviceID, error: error, refreshPreview: refresh)
        }
      )
      livePreviewSession = session
    } catch {
      isLoading = false
      lastError = error.localizedDescription
      await restoreShowTouchesIfNeeded()
    }
  }

  func stopLivePreview(refreshPreview: Bool = false) {
    guard let session = livePreviewSession else { return }
    session.cancel(refreshPreview: refreshPreview)
  }

  private func completeLivePreview(for deviceID: String, error: Error?, refreshPreview: Bool) {
    if let error {
      lastError = error.localizedDescription
    }
    livePreviewSession = nil
    livePreviewMedia = nil
    isLoading = false

    if refreshPreview {
      Task { [weak self] in
        await self?.refreshPreview(for: deviceID)
      }
    }

    Task { [weak self] in
      await self?.restoreShowTouchesIfNeeded()
    }
  }

  private func restoreShowTouchesIfNeeded() async {
    guard let deviceID = showTouchesDeviceID else { return }

    let original = showTouchesOriginalValue
    showTouchesDeviceID = nil
    showTouchesOriginalValue = nil

    guard let original else { return }

    do {
      try await adb.setShowTouches(deviceID: deviceID, enabled: original)
    } catch {
      log.error("Failed to restore show touches: \(error.localizedDescription)")
    }
  }

  private func updateShowTouches(for deviceID: String, enabled: Bool? = nil) async {
    let value = enabled ?? settings.showTouchesDuringCapture
    do {
      try await adb.setShowTouches(deviceID: deviceID, enabled: value)
    } catch {
      log.error("Failed to set show touches: \(error.localizedDescription)")
    }
  }

  private func storeOriginalShowTouches(for deviceID: String) async {
    do {
      showTouchesOriginalValue = try await adb.getShowTouches(deviceID: deviceID)
    } catch {
      showTouchesOriginalValue = nil
      log.error("Failed to query show_touches: \(error.localizedDescription)")
    }
    showTouchesDeviceID = deviceID
  }

  func applyShowTouchesSetting(_ value: Bool) async {
    guard isRecording || isLivePreviewing, let deviceID = showTouchesDeviceID else { return }
    await updateShowTouches(for: deviceID, enabled: value)
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
