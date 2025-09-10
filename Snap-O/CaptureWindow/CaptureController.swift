import AppKit
import Combine

private let log = SnapOLog.recording

@MainActor
final class CaptureController: ObservableObject {
  private let fileStore: FileStore
  private let adb: ADBService
  private let services: AppServices
  let settings: AppSettings
  private let captureService: CaptureService
  let deviceID: String
  private var cancellables: Set<AnyCancellable> = []
  private lazy var pointerInjector = LivePreviewPointerInjector(adb: adb)

  // MARK: - State (merged from CaptureViewModel)

  enum Mode {
    case idle
    case showing(Media)
    case recording(session: RecordingSession)
    case livePreview(session: LivePreviewSession, media: Media)
    case loading
    case error(String)
  }

  @Published private(set) var displayInfo: DisplayInfo?
  @Published private(set) var mode: Mode = .idle
  @Published private(set) var isStoppingLivePreview: Bool = false
  @Published private(set) var deviceUnavailableSignal: Bool = false
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
    switch mode {
    case .idle, .showing, .error:
      true
    default:
      false
    }
  }

  var isLivePreviewActive: Bool {
    if case .livePreview = mode { true } else { false }
  }

  init(
    deviceID: String,
    services: AppServices,
    settings: AppSettings
  ) {
    self.settings = settings
    self.deviceID = deviceID
    self.services = services
    adb = services.adbService
    fileStore = services.fileStore
    captureService = services.captureService

    // Forward nested object changes to this controller so SwiftUI refreshes.
    settings.objectWillChange
      .sink { [weak self] _ in self?.objectWillChange.send() }
      .store(in: &cancellables)

    settings.$showTouchesDuringCapture
      .dropFirst()
      .sink { [weak self] newValue in
        guard let self else { return }
        Task { await self.applyShowTouchesSetting(newValue) }
      }
      .store(in: &cancellables)

    Perf.step(.appFirstSnapshot, "Starting initial preview load")
    Task.detached(priority: .userInitiated) { [weak self] in
      Perf.step(.appFirstSnapshot, "consume preloaded screenshot")
      if let media = await services.captureService.consumePreloadedScreenshot(for: deviceID) {
        Perf.step(.appFirstSnapshot, "Using preloaded screenshot")
        Task { @MainActor [weak self] in
          self?.mode = .showing(media)
          self?.updateSizingMedia(with: media)
        }
        return
      }

      Perf.step(.appFirstSnapshot, "Preload missing; refreshing preview")
      await self?.refreshPreview()
    }
  }

  convenience init(
    deviceID: String
  ) {
    self.init(
      deviceID: deviceID,
      services: AppServices.shared,
      settings: AppSettings.shared
    )
  }

  func handle(url: URL) {
    // snapo://record or snapo://capture
    guard let host = url.host, let cmd = SnapOCommand(rawValue: host) else { return }
    NSApp.activate(ignoringOtherApps: true)
    pendingCommand = cmd
    Task { await refreshPreview() }
  }

  func sendPointerEvent(
    action: LivePreviewPointerAction,
    source: LivePreviewPointerSource,
    location: CGPoint
  ) {
    guard case .livePreview = mode else { return }
    let command = LivePreviewPointerEvent(deviceID: deviceID, action: action, source: source, location: location)
    Task {
      await pointerInjector.enqueue(command)
    }
  }

  func stopRecording() async {
    guard case .recording(let session) = mode else { return }
    Perf.step(.appFirstSnapshot, "before: Stop Recording → Render")
    Perf.startIfNeeded(.recordingRender, name: "Stop Recording → Video Rendered")
    Perf.step(.recordingRender, "begin stopRecording")
    mode = .loading

    do {
      Perf.step(.recordingRender, "invoking captureService.stopRecording")
      if let media = try await captureService.stopRecording(session: session, deviceID: deviceID) {
        Perf.step(.recordingRender, "captureService returned media")
        mode = .showing(media)
        updateSizingMedia(with: media)
        Perf.step(.recordingRender, "mode set to .showing")
      } else {
        mode = .idle
      }
    } catch {
      handleDeviceFailure(error)
    }

    await restoreShowTouchesIfNeeded()
  }

  func stopLivePreview(withRefresh refresh: Bool = false) async {
    guard case .livePreview(let session, _) = mode else { return }
    isStoppingLivePreview = true
    mode = .loading

    let error = await captureService.stopLivePreview(session: session)
    if let error {
      handleDeviceFailure(error)
    } else {
      mode = .idle
    }

    await restoreShowTouchesIfNeeded()

    if refresh {
      await refreshPreview()
    }
    isStoppingLivePreview = false
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

  // MARK: - Internal merged operations

  func copy() {
    guard let media = currentMedia, case .image(let url, _) = media else { return }
    guard let image = NSImage(contentsOf: url) else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.writeObjects([image])
  }

  private func refreshProjectedMediaIfNeeded() {
    guard currentMedia == nil else { return }
    Task {
      guard let displayInfo = await fetchProjectedDisplayInfo() else { return }
      await MainActor.run { updateProjectedSize(displayInfo) }
    }
  }

  private func fetchProjectedDisplayInfo() async -> DisplayInfo? {
    do {
      let adbService = AppServices.shared.adbService
      let exec = await adbService.exec()
      let sizeString = try await exec.displaySize(deviceID: deviceID)
      guard let size = parseDisplaySize(sizeString) else { return nil }
      let density = try? await exec.displayDensity(deviceID: deviceID)
      return DisplayInfo(size: size, densityScale: density)
    } catch {
      return nil
    }
  }

  private func parseDisplaySize(_ rawValue: String) -> CGSize? {
    let parts = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "x")
    guard parts.count == 2,
          let width = Double(parts[0]),
          let height = Double(parts[1])
    else { return nil }
    return CGSize(width: width, height: height)
  }

  func refreshPreview() async {
    guard canCapture else { return }
    Perf.step(.appFirstSnapshot, "before: Snapshot Request")
    Perf.startIfNeeded(.captureRequest, name: "Snapshot Request → Render")
    Perf.step(.captureRequest, "begin refreshPreview")

    if pendingCommand == .record {
      pendingCommand = nil
      await startRecording()
      return
    }
    if pendingCommand == .livepreview {
      pendingCommand = nil
      await startLivePreview()
      return
    }
    pendingCommand = nil
    Perf.step(.captureRequest, "clearing current media")
    await clearCurrentMedia()
    mode = .loading

    refreshProjectedMediaIfNeeded()

    do {
      Perf.step(.captureRequest, "invoking captureService.captureScreenshot")
      let media = try await captureService.captureScreenshot(for: deviceID)
      Perf.step(.captureRequest, "captureService returned media")
      mode = .showing(media)
      updateSizingMedia(with: media)
      Perf.step(.captureRequest, "mode set to .showing")
    } catch {
      handleDeviceFailure(error)
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

  func startRecording() async {
    guard canStartRecordingNow else { return }
    log.info("Start recording for device=\(self.deviceID, privacy: .private)")
    Perf.step(.appFirstSnapshot, "before: Start Recording")
    Perf.startIfNeeded(.recordingStart, name: "Start Recording Request → Recording Started")
    Perf.step(.recordingStart, "begin startRecording")
    await clearCurrentMedia()
    mode = .loading
    refreshProjectedMediaIfNeeded()
    do {
      await storeOriginalShowTouches(for: deviceID)
      await updateShowTouches(for: deviceID)

      let session = try await captureService.startRecording(for: deviceID)
      mode = .recording(session: session)
      Perf.step(.recordingStart, "session started; mode .recording")
      Perf.end(.recordingStart, finalLabel: "recording started")
      Perf.step(.appFirstSnapshot, "after: Start Recording")
    } catch {
      handleDeviceFailure(error)
      await restoreShowTouchesIfNeeded()
    }
  }

  func startLivePreview() async {
    guard canStartLivePreviewNow else { return }
    log.info("Start live preview for device=\(self.deviceID, privacy: .private)")
    Perf.step(.appFirstSnapshot, "before: Start Live Preview")
    Perf.startIfNeeded(.livePreviewStart, name: "Start Live Preview Request → First Frame")
    Perf.step(.livePreviewStart, "begin startLivePreview")
    await clearCurrentMedia()
    mode = .loading

    do {
      await storeOriginalShowTouches(for: deviceID)
      await updateShowTouches(for: deviceID)

      let session = try await captureService.startLivePreview(for: deviceID)
      let media = try await session.waitUntilReady()
      mode = .livePreview(session: session, media: media)
      updateSizingMedia(with: media)
      Perf.step(.livePreviewStart, "session ready; mode .livePreview")
    } catch {
      handleDeviceFailure(error)
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

  private func handleDeviceFailure(_ error: Error) {
    if isDeviceUnavailableError(error) {
      deviceUnavailableSignal.toggle()
    }
    mode = .error(error.localizedDescription)
  }

  private func isDeviceUnavailableError(_ error: Error) -> Bool {
    guard let adbError = error as? ADBError else { return false }
    if case .nonZeroExit(_, let stderr) = adbError {
      let message = stderr?.lowercased() ?? ""
      return message.contains("device offline") ||
        message.contains("device not found") ||
        message.contains("no devices/emulators found")
    }
    return false
  }

  func updateProjectedSize(_ displayInfo: DisplayInfo?) {
    guard currentMedia == nil else { return }
    self.displayInfo = displayInfo
  }

  private func updateSizingMedia(with media: Media) {
    displayInfo = media.common.display
  }
}
