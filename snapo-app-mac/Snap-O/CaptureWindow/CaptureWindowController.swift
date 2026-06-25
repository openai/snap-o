import AppKit
import Foundation
import Observation
import SnapODeviceClient
import SwiftUI

@Observable
@MainActor
final class CaptureWindowController {
  @ObservationIgnored private let screenshotService: ScreenshotService
  @ObservationIgnored private let recordingService: RecordingService
  @ObservationIgnored private let livePreviewService: LivePreviewService
  @ObservationIgnored private let deviceTracker: DeviceTracker
  @ObservationIgnored private let adbService: ADBService
  let fileStore: FileStore

  let snapshotController = CaptureSnapshotController()
  let mediaDisplayMode: MediaDisplayMode

  private(set) var isDeviceListInitialized: Bool = false
  private(set) var isProcessing: Bool = false
  private(set) var lastError: String?
  private(set) var screenshotFailures: [CaptureFailure] = []
  private(set) var mode: CaptureWindowMode

  private var knownDevices: [Device] = []
  @ObservationIgnored private var deviceStreamTask: Task<Void, Never>?
  private var pendingPreferredDeviceID: String?
  @ObservationIgnored private var isPreloadConsumptionActive = false
  @ObservationIgnored private var hasAttemptedInitialPreload = false
  @ObservationIgnored private var cachedCaptureProgressText: String?
  @ObservationIgnored private var isTornDown = false

  init(
    captureServices: CaptureServices,
    deviceTracker: DeviceTracker,
    fileStore: FileStore,
    adbService: ADBService
  ) {
    screenshotService = captureServices.screenshots
    recordingService = captureServices.recording
    livePreviewService = captureServices.livePreview
    self.deviceTracker = deviceTracker
    self.fileStore = fileStore
    self.adbService = adbService
    mediaDisplayMode = MediaDisplayMode(snapshotController: snapshotController)
    mode = .idle
  }

  func start() async {
    isTornDown = false
    deviceStreamTask?.cancel()
    let tracker = deviceTracker
    let latestDevices = await tracker.latestDevices
    isDeviceListInitialized = !latestDevices.isEmpty

    deviceStreamTask = Task { [weak self] in
      guard let self else { return }
      let stream = await tracker.deviceStream()
      for await devices in stream {
        await MainActor.run {
          self.handleDeviceUpdate(devices)
          if !self.isDeviceListInitialized { self.isDeviceListInitialized = true }
        }
      }
    }
  }

  func selectMedia(id: CaptureMedia.ID) {
    snapshotController.selectMedia(id: id)
  }

  func selectMedia(id: CaptureMedia.ID?) {
    snapshotController.selectMedia(id: id)
  }

  func selectNextMedia() {
    snapshotController.selectNextMedia()
  }

  func selectPreviousMedia() {
    snapshotController.selectPreviousMedia()
  }

  func selectDevice(id: String) {
    guard selectedDeviceID != id else { return }
    pendingPreferredDeviceID = id
    mediaDisplayMode.updateLastViewedDeviceID(id)
    if let media = mediaList.first(where: { $0.device.id == id }) {
      mediaDisplayMode.selectMedia(id: media.id)
    }
  }

  func hasAlternativeMedia() -> Bool {
    snapshotController.hasAlternativeMedia
  }

  func dismissScreenshotFailures() {
    screenshotFailures = []
    lastError = nil
  }

  var hasDevices: Bool {
    !knownDevices.isEmpty
  }

  var isRecording: Bool {
    if case .recording = mode { return true }
    return false
  }

  var isLivePreviewActive: Bool {
    if case .livePreview = mode { return true }
    return false
  }

  var isStoppingLivePreview: Bool {
    if case .livePreview(let livePreviewMode) = mode {
      return livePreviewMode.isStopping
    }
    return false
  }

  var canCaptureNow: Bool {
    !isTornDown && !isProcessing && !isRecording && !isLivePreviewActive && hasDevices
  }

  var canStartRecordingNow: Bool {
    !isTornDown && !isProcessing && !isRecording && !isLivePreviewActive && hasDevices
  }

  var canStartLivePreviewNow: Bool {
    !isTornDown && !isProcessing && !isRecording && !isLivePreviewActive && hasDevices
  }

  var mediaList: [CaptureMedia] {
    mediaDisplayMode.mediaList
  }

  var selectedMediaID: CaptureMedia.ID? {
    mediaDisplayMode.selectedMediaID
  }

  var selectedDeviceID: String? {
    currentCapture?.device.id ?? lastViewedDeviceID
  }

  var currentCaptureViewID: UUID? {
    mediaDisplayMode.currentCaptureViewID
  }

  var shouldShowPreviewHint: Bool {
    mediaDisplayMode.shouldShowPreviewHint
  }

  var overlayMediaList: [CaptureMedia] {
    mediaDisplayMode.overlayMediaList
  }

  var lastViewedDeviceID: String? {
    mediaDisplayMode.lastViewedDeviceID
  }

  var currentCapture: CaptureMedia? {
    mediaDisplayMode.currentCapture
  }

  var navigationTitle: String {
    currentCapture?.device.displayTitle ?? "Snap-O"
  }

  var currentCaptureDeviceTitle: String? {
    currentCapture?.device.displayTitle
  }

  var captureProgressText: String? {
    if let progress = mediaDisplayMode.captureProgressText {
      cachedCaptureProgressText = progress
      return progress
    }

    guard isProcessing || isRecording else {
      cachedCaptureProgressText = nil
      return nil
    }

    return cachedCaptureProgressText
  }

  var displayInfoForSizing: DisplayInfo? {
    if isRecording {
      return mediaDisplayMode.lastPreviewDisplayInfo ?? currentCapture?.media.common.display
    }
    return currentCapture?.media.common.display
  }

  func captureScreenshots() async {
    guard canCaptureNow else { return }
    cancelPreloadConsumptionIfNeeded()
    isProcessing = true
    lastError = nil
    screenshotFailures = []
    if pendingPreferredDeviceID == nil {
      pendingPreferredDeviceID = currentCapture?.device.id ?? lastViewedDeviceID
    }
    mediaDisplayMode.updateMediaList(
      [],
      preserveDeviceID: nil,
      shouldSort: false
    )

    let screenshotMode = PreparingScreenshotMode(
      screenshotService: screenshotService,
      devices: knownDevices
    ) { [weak self] result in
      guard let self, !isTornDown else { return }
      applyScreenshotCaptureResult(result)
    }
    mode = .preparingScreenshot(screenshotMode)
    screenshotMode.start()
  }

  func startRecording() async {
    guard canStartRecordingNow else { return }
    cancelPreloadConsumptionIfNeeded()
    let devices = knownDevices
    isProcessing = true
    lastError = nil
    screenshotFailures = []
    pendingPreferredDeviceID = currentCapture?.device.id
    mediaDisplayMode.updateMediaList(
      [],
      preserveDeviceID: nil,
      shouldSort: false
    )
    let recordingMode = RecordingMode(
      recordingService: recordingService,
      devices: devices,
      options: RecordingOptions(
        recordsBugReport: AppSettings.shared.recordAsBugReport,
        showsTouches: AppSettings.shared.showTouchesDuringCapture
      )
    ) { [weak self] result in
      guard let self, !isTornDown else { return }
      switch result {
      case .failed(let error):
        lastError = error.localizedDescription
        isProcessing = false
        mode = .idle
      case .completed(let media, let error):
        if error == nil, media.isEmpty {
          mode = .idle
          Task {
            isProcessing = false
            await self.captureScreenshots()
          }
        } else {
          applyCaptureResults(newMedia: media, encounteredError: error)
        }
      }
    }
    mode = .recording(recordingMode)
    recordingMode.start()
    isProcessing = false
  }

  func stopRecording() async {
    guard isRecording else { return }
    guard case .recording(let recordingMode) = mode else { return }

    isProcessing = true
    lastError = nil
    screenshotFailures = []

    await recordingMode.finish()
  }

  func startLivePreview() async {
    guard canStartLivePreviewNow else { return }
    cancelPreloadConsumptionIfNeeded()
    isProcessing = true
    lastError = nil
    screenshotFailures = []
    let preferredDeviceID = currentCapture?.device.id ?? lastViewedDeviceID ?? knownDevices.first?.id
    pendingPreferredDeviceID = preferredDeviceID

    let livePreviewMode = LivePreviewMode(
      livePreviewService: livePreviewService,
      adbService: adbService,
      options: LivePreviewOptions(
        showsTouches: AppSettings.shared.showTouchesDuringCapture
      ),
      mediaDisplayMode: mediaDisplayMode,
      preferredDeviceIDProvider: { [weak self] in
        guard let self else { return nil }
        if let pending = pendingPreferredDeviceID {
          return pending
        }
        if let currentID = selectedMediaID,
           let current = mediaList.first(where: { $0.id == currentID }) {
          return current.device.id
        }
        return nil
      },
      onMediaApplied: { [weak self] in
        guard let self, !isTornDown else { return }
        isProcessing = false
        pendingPreferredDeviceID = nil
      },
      errorHandler: { [weak self] error in
        self?.lastError = error.localizedDescription
      }
    )
    mode = .livePreview(livePreviewMode)
    await livePreviewMode.start(with: knownDevices)
    guard !isTornDown else { return }
    isProcessing = false
  }

  func stopLivePreview() async {
    guard case .livePreview(let livePreviewMode) = mode else { return }
    guard !livePreviewMode.isStopping else { return }
    let preferredDeviceID = currentCapture?.device.id ?? lastViewedDeviceID
    await livePreviewMode.stop()
    guard !isTornDown else { return }
    pendingPreferredDeviceID = preferredDeviceID
    if let preferredDeviceID { mediaDisplayMode.updateLastViewedDeviceID(preferredDeviceID) }
    if !hasDevices {
      isProcessing = false
      pendingPreferredDeviceID = nil
      mode = .idle
      return
    }
    if isProcessing { isProcessing = false }
    mode = .idle
    await captureScreenshots()
  }

  func tearDown() async {
    guard !isTornDown else { return }
    isTornDown = true
    deviceStreamTask?.cancel()
    deviceStreamTask = nil

    let activeMode = mode
    mode = .idle
    pendingPreferredDeviceID = nil
    if case .preparingScreenshot(let screenshotMode) = activeMode {
      screenshotMode.cancel()
    }
    if case .checkingPreload(let preloadMode) = activeMode {
      preloadMode.cancel()
    }
    if case .recording(let recordingMode) = activeMode {
      await recordingMode.cancel()
    }
    if case .livePreview(let livePreviewMode) = activeMode {
      await livePreviewMode.stop()
    }
    isPreloadConsumptionActive = false
    hasAttemptedInitialPreload = false
    mediaDisplayMode.tearDown()
  }

  func copyCurrentImage() {
    guard let capture = currentCapture,
          case .image(let url, _) = capture.media,
          let image = NSImage(contentsOf: url)
    else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.writeObjects([image])
  }

  private func applyPreloadedMedia(_ mediaList: [CaptureMedia]) {
    mediaDisplayMode.updateMediaList(
      mediaList,
      preserveDeviceID: mediaList.first?.device.id,
      shouldSort: false
    )
    mode = .displaying(mediaDisplayMode)
  }

  private func applyScreenshotCaptureResult(_ result: ScreenshotCaptureResult) {
    screenshotFailures = result.failures.sorted {
      $0.device.displayTitle.localizedCaseInsensitiveCompare($1.device.displayTitle) == .orderedAscending
    }
    let error = result.failures.first?.error
    applyCaptureResults(newMedia: result.media, encounteredError: error)
    if !result.failures.isEmpty {
      lastError = result.failures.map(\.message).joined(separator: "\n")
    }
  }

  private func applyCaptureResults(
    newMedia: [CaptureMedia],
    encounteredError: Error?
  ) {
    if let error = encounteredError {
      lastError = error.localizedDescription
      if mediaDisplayMode.mediaList.isEmpty {
        mode = .error(message: error.localizedDescription)
      }
    }

    if !newMedia.isEmpty {
      let targetDeviceID = pendingPreferredDeviceID ?? currentCapture?.device.id
        ?? lastViewedDeviceID
      mediaDisplayMode.updateMediaList(
        newMedia,
        preserveDeviceID: targetDeviceID,
        shouldSort: true
      )
      mode = .displaying(mediaDisplayMode)
    } else if mediaDisplayMode.mediaList.isEmpty {
      mode = .idle
    }

    isProcessing = false
    pendingPreferredDeviceID = nil
  }

  private func handleDeviceUpdate(_ devices: [Device]) {
    guard !isTornDown else { return }
    knownDevices = devices
    if mediaList.isEmpty {
      mediaDisplayMode.clearSelection()
    }
    if !devices.isEmpty {
      startPreloadConsumptionIfNeeded()
    }
    Task { @MainActor [weak self] in
      guard let self else { return }
      if case .recording(let recordingMode) = mode {
        await recordingMode.updateDevices(devices)
      }
      if case .livePreview(let livePreviewMode) = mode {
        await livePreviewMode.updateDevices(devices)
      }
    }
  }

  private func startPreloadConsumptionIfNeeded() {
    guard !isPreloadConsumptionActive else { return }
    guard !hasAttemptedInitialPreload else { return }
    guard mediaList.isEmpty else { return }
    guard case .idle = mode else { return }
    isPreloadConsumptionActive = true
    hasAttemptedInitialPreload = true
    let preloadMode = CheckPreloadMode(
      screenshotService: screenshotService,
      devices: knownDevices
    ) { [weak self] outcome in
      guard let self, !isTornDown else { return }
      guard case .checkingPreload = mode else { return }
      isPreloadConsumptionActive = false
      switch outcome {
      case .found(let media):
        applyPreloadedMedia(media)
        isProcessing = false
      case .missing:
        Task { [weak self] in
          await self?.captureScreenshots()
        }
      }
    }
    mode = .checkingPreload(preloadMode)
    preloadMode.start()
  }

  private func cancelPreloadConsumptionIfNeeded() {
    guard case .checkingPreload(let preloadMode) = mode else { return }
    preloadMode.cancel()
    isPreloadConsumptionActive = false
  }

  func startLivePreviewStream(for deviceID: String) async -> LivePreviewRenderer? {
    guard case .livePreview(let livePreviewMode) = mode else { return nil }
    guard !livePreviewMode.isStopping else { return nil }
    do {
      let renderer = try await livePreviewMode.makeRenderer(for: deviceID)
      guard case .livePreview(let currentMode) = mode,
            currentMode === livePreviewMode,
            !currentMode.isStopping else {
        _ = await livePreviewService.stop(renderer.operation)
        return nil
      }
      lastError = nil
      return renderer
    } catch {
      guard case .livePreview(let currentMode) = mode,
            currentMode === livePreviewMode,
            !currentMode.isStopping,
            !(error is CancellationError) else { return nil }
      lastError = error.localizedDescription
      return nil
    }
  }

  func stopLivePreviewStream(_ renderer: LivePreviewRenderer) async {
    if case .livePreview(let livePreviewMode) = mode {
      await livePreviewMode.stopRenderer(renderer)
    } else {
      _ = await livePreviewService.stop(renderer.operation)
    }
  }

  func setPreviewHintHovering(_ isHovering: Bool) {
    mediaDisplayMode.setPreviewHintHovering(isHovering)
  }

  func setProgressHovering(_ isHovering: Bool) {
    mediaDisplayMode.setProgressHovering(isHovering)
  }
}

extension CaptureWindowController: LivePreviewHosting {}
