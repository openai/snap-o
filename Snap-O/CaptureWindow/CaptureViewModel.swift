import AppKit
@preconcurrency import AVKit
import Observation

private let log = SnapOLog.ui

@MainActor
@Observable
final class CaptureViewModel {
  var currentMedia: Media?
  var isLoading = false
  var isRecording: Bool { recordingSession != nil }
  var recordingDeviceID: String?
  var recordingSession: RecordingSession?
  var lastError: String?
  var pendingCommand: SnapOCommand?
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
  var canStartLivePreview: Bool { !isLoading && !isRecording && livePreviewSession == nil }
  var canStopLivePreview: Bool { livePreviewSession != nil }

  func copy() {
    guard let media = currentMedia, case let .image(url, _) = media else { return }
    guard let image = NSImage(contentsOf: url) else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.writeObjects([image])
  }

  // Screenshot
  func refreshPreview(for deviceID: String) async {
    guard !isLoading, !isRecording else { return }
    clearCurrentMedia()
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
      let dest = store.makePreviewDestination(deviceID: deviceID, kind: .image)

      async let writeAndSize: CGSize = Task.detached(priority: .utility) {
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

      currentMedia = .image(
        url: dest,
        capturedAt: capturedAt,
        size: size,
        densityScale: density
      )
      lastError = nil
    } catch {
      clearCurrentMedia()
      lastError = error.localizedDescription
    }
  }

  func makeTempDragFile(kind: MediaSaveKind) -> URL? {
    guard let media = currentMedia, let srcURL = media.url else { return nil }

    do {
      let url = store.makeDragDestination(
        capturedAt: media.capturedAt,
        kind: kind
      )
      try FileManager.default.copyItem(at: srcURL, to: url)
      return url
    } catch {
      log.error("Drag temp copy failed: \(error.localizedDescription)")
      return nil
    }
  }

  // Recording
  func startRecording(for deviceID: String) async {
    guard !isLoading, !isRecording else { return }
    clearCurrentMedia()
    isLoading = true
    defer { isLoading = false }
    do {
      await storeOriginalShowTouches(for: deviceID)
      await updateShowTouches(for: deviceID)

      let session = try await adb.startScreenrecord(deviceID: deviceID)
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
    recordingDeviceID = nil
    recordingSession = nil
    isLoading = true
    defer { isLoading = false }
    do {
      let dest = store.makePreviewDestination(deviceID: deviceID, kind: .video)
      try await adb.stopScreenrecord(session: session, savingTo: dest)
      let asset = AVURLAsset(url: dest)

      let densityTask = Task<CGFloat?, Never> { [adb, deviceID] in
        try? await adb.screenDensityScale(deviceID: deviceID)
      }

      if let media = try await Media.video(
        from: asset,
        url: dest,
        capturedAt: Date(),
        densityProvider: { await densityTask.value }
      ) {
        currentMedia = media
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
    clearCurrentMedia()
    isLoading = true
    lastError = nil

    do {
      await storeOriginalShowTouches(for: deviceID)
      await updateShowTouches(for: deviceID)

      let session = try await LivePreviewSession(
        deviceID: deviceID,
        adb: adb,
        onReady: { [weak self] media in
          self?.currentMedia = media
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
    clearCurrentMedia()
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
    guard isRecording || livePreviewSession != nil, let deviceID = showTouchesDeviceID else { return }
    await updateShowTouches(for: deviceID, enabled: value)
  }

  private func clearCurrentMedia() {
    if livePreviewSession != nil {
      stopLivePreview()
    }
    currentMedia = nil
  }
}
