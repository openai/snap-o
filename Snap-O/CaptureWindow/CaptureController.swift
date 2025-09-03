import AppKit
import SwiftUI

private let log = SnapOLog.recording

@MainActor
@Observable
final class CaptureController {
  private let fileStore: FileStore
  private let adb: ADBService
  let settings: AppSettings
  private let captureService: CaptureService

  let devices = DeviceSelection()

  // MARK: - State (merged from CaptureViewModel)

  enum Mode {
    case idle
    case showing(Media)
    case recording(session: RecordingSession)
    case livePreview(session: LivePreviewSession, media: Media)
    case loading
    case error(String)
  }

  var mode: Mode = .idle
  var pendingCommand: SnapOCommand?

  private var showTouchesOriginalValue: Bool?
  private var showTouchesDeviceID: String?

  var currentMedia: Media? {
    switch mode {
    case .showing(let media):
      media
    case .livePreview(_, let media):
      media
    default:
      nil
    }
  }

  var isLoading: Bool {
    if case .loading = mode { true } else { false }
  }

  var isRecording: Bool {
    if case .recording = mode { true } else { false }
  }

  var livePreviewSession: LivePreviewSession? {
    switch mode {
    case .livePreview(let session, _):
      session
    default:
      nil
    }
  }

  var lastError: String? {
    if case .error(let message) = mode { message } else { nil }
  }

  var canCapture: Bool {
    devices.currentDevice != nil && {
      switch mode {
      case .idle, .showing, .error:
        true
      default:
        false
      }
    }()
  }

  init(services: AppServices) {
    settings = services.settings
    adb = services.adbService
    fileStore = services.fileStore
    captureService = services.captureService
  }

  func handle(url: URL) {
    // snapo://record or snapo://capture
    guard let host = url.host, let cmd = SnapOCommand(rawValue: host) else { return }
    NSApp.activate(ignoringOtherApps: true)
    pendingCommand = cmd
    Task { await refreshPreview() }
  }

  func refreshPreview() async {
    guard let deviceID = devices.currentDevice?.id else { return }
    await refreshPreview(for: deviceID)
  }

  func startRecording() async {
    guard let deviceID = devices.currentDevice?.id else { return }
    log.info("Start recording for device=\(deviceID, privacy: .public)")
    await startRecording(for: deviceID)
  }

  func stopRecording() async {
    guard case .recording(let session) = mode else { return }
    mode = .loading

    do {
      if let media = try await captureService.stopRecording(session: session, deviceID: session.deviceID) {
        mode = .showing(media)
      } else {
        mode = .idle
      }
    } catch {
      mode = .error(error.localizedDescription)
    }

    await restoreShowTouchesIfNeeded()
  }

  func startLivePreview() async {
    guard let deviceID = devices.currentDevice?.id else { return }
    log.info("Start live preview for device=\(deviceID, privacy: .public)")
    await startLivePreview(for: deviceID)
  }

  func stopLivePreview(withRefresh refresh: Bool = false) async {
    guard case .livePreview(let session, _) = mode else { return }
    mode = .loading

    let error = await captureService.stopLivePreview(session: session)
    if let error {
      mode = .error(error.localizedDescription)
    } else {
      mode = .idle
    }

    await restoreShowTouchesIfNeeded()

    if refresh {
      await refreshPreview(for: session.deviceID)
    }
  }

  var canStartRecordingNow: Bool { canCapture }

  var canStartLivePreviewNow: Bool { canCapture }

  var showTouchesDuringCapture: Bool {
    get { settings.showTouchesDuringCapture }
    set { settings.showTouchesDuringCapture = newValue }
  }

  func applyShowTouchesSetting(_ value: Bool) async {
    guard let deviceID = showTouchesDeviceID else { return }
    await updateShowTouches(for: deviceID, enabled: value)
  }

  // MARK: - Device Selection

  func onDevicesChanged(_ list: [Device]) {
    devices.updateDevices(list)
  }

  var currentDevice: Device? { devices.currentDevice }

  func selectNextDevice() {
    devices.selectNext()
  }

  func selectPreviousDevice() {
    devices.selectPrevious()
  }

  // MARK: - Internal merged operations

  func copy() {
    guard let media = currentMedia, case .image(let url, _) = media else { return }
    guard let image = NSImage(contentsOf: url) else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.writeObjects([image])
  }

  func refreshPreview(for deviceID: String) async {
    guard canCapture else { return }

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

    await clearCurrentMedia()
    mode = .loading
    do {
      let media = try await captureService.captureScreenshot(for: deviceID)
      mode = .showing(media)
    } catch {
      mode = .error(error.localizedDescription)
    }
  }

  func makeTempDragFile(kind: MediaSaveKind) -> URL? {
    guard let media = currentMedia, let srcURL = media.url else { return nil }

    do {
      let url = fileStore.makeDragDestination(
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

  func startRecording(for deviceID: String) async {
    guard canStartRecordingNow else { return }
    await clearCurrentMedia()
    mode = .loading
    do {
      await storeOriginalShowTouches(for: deviceID)
      await updateShowTouches(for: deviceID)

      let session = try await captureService.startRecording(for: deviceID)
      mode = .recording(session: session)
    } catch {
      mode = .error(error.localizedDescription)
      await restoreShowTouchesIfNeeded()
    }
  }

  func startLivePreview(for deviceID: String) async {
    guard canStartLivePreviewNow else { return }
    await clearCurrentMedia()
    mode = .loading

    do {
      await storeOriginalShowTouches(for: deviceID)
      await updateShowTouches(for: deviceID)

      let session = try await captureService.startLivePreview(for: deviceID)
      let media = try await session.waitUntilReady()
      mode = .livePreview(session: session, media: media)
    } catch {
      mode = .error(error.localizedDescription)
      await restoreShowTouchesIfNeeded()
    }
  }

  // MARK: - Show Touches helpers

  private func restoreShowTouchesIfNeeded() async {
    guard let deviceID = showTouchesDeviceID else { return }

    let original = showTouchesOriginalValue
    showTouchesDeviceID = nil
    showTouchesOriginalValue = nil

    guard let original else { return }

    do {
      try await adb.exec().setShowTouches(deviceID: deviceID, enabled: original)
    } catch {
      log.error("Failed to restore show touches: \(error.localizedDescription)")
    }
  }

  private func updateShowTouches(for deviceID: String, enabled: Bool? = nil) async {
    let value = enabled ?? settings.showTouchesDuringCapture
    do {
      try await adb.exec().setShowTouches(deviceID: deviceID, enabled: value)
    } catch {
      log.error("Failed to set show touches: \(error.localizedDescription)")
    }
  }

  private func storeOriginalShowTouches(for deviceID: String) async {
    do {
      showTouchesOriginalValue = try await adb.exec().getShowTouches(deviceID: deviceID)
    } catch {
      showTouchesOriginalValue = nil
      log.error("Failed to query show_touches: \(error.localizedDescription)")
    }
    showTouchesDeviceID = deviceID
  }

  private func clearCurrentMedia() async {
    switch mode {
    case .livePreview:
      await stopLivePreview()
    case .showing, .error:
      mode = .idle
    default:
      break
    }
  }
}
