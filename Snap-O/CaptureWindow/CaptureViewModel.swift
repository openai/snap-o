import AppKit
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
  private let captureService: CaptureService

  private var showTouchesOriginalValue: Bool?
  private var showTouchesDeviceID: String?

  init(adb: ADBClient, store: FileStore, settings: AppSettings, captureService: CaptureService) {
    self.adb = adb
    self.store = store
    self.settings = settings
    self.captureService = captureService
  }

  // MARK: - Convenience State

  var canCapture: Bool { !isLoading && !isRecording }
  var canStartRecording: Bool { !isLoading && !isRecording }
  var canStopRecording: Bool { isRecording }
  var canStartLivePreview: Bool { !isLoading && !isRecording && livePreviewSession == nil }
  var canStopLivePreview: Bool { livePreviewSession != nil }

  func copy() {
    guard let media = currentMedia, case .image(let url, _) = media else { return }
    guard let image = NSImage(contentsOf: url) else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.writeObjects([image])
  }

  // Screenshot
  func refreshPreview(for deviceID: String) async {
    guard !isLoading, !isRecording else { return }
    await clearCurrentMedia()
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
      currentMedia = try await captureService.captureScreenshot(for: deviceID)
      lastError = nil
    } catch {
      await clearCurrentMedia()
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
    await clearCurrentMedia()
    isLoading = true
    defer { isLoading = false }
    do {
      await storeOriginalShowTouches(for: deviceID)
      await updateShowTouches(for: deviceID)

      let session = try await captureService.startRecording(for: deviceID)
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
      if let media = try await captureService.stopRecording(session: session, deviceID: deviceID) {
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
    await clearCurrentMedia()
    isLoading = true
    lastError = nil

    do {
      await storeOriginalShowTouches(for: deviceID)
      await updateShowTouches(for: deviceID)

      let session = try await captureService.startLivePreview(for: deviceID)
      livePreviewSession = session

      let media = try await session.waitUntilReady()
      currentMedia = media
      isLoading = false
      lastError = nil
    } catch {
      isLoading = false
      lastError = error.localizedDescription
      await restoreShowTouchesIfNeeded()
    }
  }

  func stopLivePreview(refreshPreview: Bool = false) async {
    guard let session = livePreviewSession else { return }
    let error = await captureService.stopLivePreview(session: session)
    if let error {
      lastError = error.localizedDescription
    }
    livePreviewSession = nil
    await clearCurrentMedia()
    isLoading = false

    Task { [weak self] in
      await self?.restoreShowTouchesIfNeeded()
    }

    if refreshPreview {
      Task { [weak self] in
        await self?.refreshPreview(for: session.deviceID)
      }
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

  private func clearCurrentMedia() async {
    if livePreviewSession != nil {
      await stopLivePreview()
    }
    currentMedia = nil
  }
}
