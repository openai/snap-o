import AppKit
import Foundation
import Observation
import SwiftUI

@Observable
@MainActor
final class CaptureWindowController {
  let captureCoordinator: CaptureCoordinator
  @ObservationIgnored private let screenshotService: ScreenshotService
  @ObservationIgnored private let recordingService: RecordingService
  @ObservationIgnored private let livePreviewService: LivePreviewService
  @ObservationIgnored private let startupPreparation: StartupCapturePreparation
  @ObservationIgnored private let deviceManager: DeviceManager
  @ObservationIgnored private let adbService: ADBService
  let fileStore: FileStore

  let snapshotController = CaptureSnapshotController()
  let mediaDisplayMode: MediaDisplayMode

  private(set) var isDeviceListInitialized: Bool = false
  private(set) var isProcessing: Bool = false
  var isSavingReview = false
  var reviewCrops: [UUID: CGRect] = [:]
  private(set) var lastError: String?
  private(set) var screenshotFailures: [CaptureFailure] = []
  private(set) var imageCopyID: UUID?
  private var recordingMode: RecordingMode?
  private(set) var isFinishingRecording = false
  private(set) var mode: CaptureWindowMode
  var deviceOpenRequest: DeviceOpenRequest?

  private var knownDevices: [Device] = []
  @ObservationIgnored private var pendingCommands: [SnapOCommand] = []
  @ObservationIgnored private var usesPreviewDeviceStream = false
  @ObservationIgnored private var deviceStreamTask: Task<Void, Never>?
  private var pendingPreferredDeviceID: String?
  @ObservationIgnored private var hasStartedInitialCapture = false
  @ObservationIgnored private var initialCaptureTask: Task<Void, Never>?
  @ObservationIgnored private var initialCaptureWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
  @ObservationIgnored private var cachedCaptureProgressText: String?
  @ObservationIgnored private var isTornDown = false

  init(
    captureServices: CaptureServices,
    deviceManager: DeviceManager,
    fileStore: FileStore,
    adbService: ADBService
  ) {
    captureCoordinator = captureServices.coordinator
    screenshotService = captureServices.screenshots
    recordingService = captureServices.recording
    livePreviewService = captureServices.livePreview
    startupPreparation = captureServices.startup
    self.deviceManager = deviceManager
    self.fileStore = fileStore
    self.adbService = adbService
    mediaDisplayMode = MediaDisplayMode(snapshotController: snapshotController)
    mode = .idle
  }

  func start() async {
    #if PERF_TRACING
    Perf.startupEvent("window controller start")
    #endif
    guard !isTornDown, deviceStreamTask == nil else { return }
    let usePreview = deviceOpenRequest != nil || (pendingCommands.first.map { $0 == .livepreview }
      ?? (usesPreviewDeviceStream || AppSettings.shared.startupCaptureMode == .livePreview))
    isDeviceListInitialized = !deviceManager.latestDevices.isEmpty
    observeDevices(usePreview: usePreview)
  }

  private func observeDevices(usePreview: Bool) {
    if usesPreviewDeviceStream != usePreview { knownDevices = [] }
    usesPreviewDeviceStream = usePreview
    deviceStreamTask?.cancel()
    let manager = deviceManager
    deviceStreamTask = Task { [weak self] in
      guard let self else { return }
      let stream = if usePreview {
        manager.previewDeviceStream()
      } else {
        manager.deviceStream()
      }
      for await devices in stream {
        guard !Task.isCancelled else { return }
        handleDeviceUpdate(devices)
        if !isDeviceListInitialized { isDeviceListInitialized = true }
      }
    }
  }

  var adbServerState: ADBServerState {
    deviceManager.adbServerState
  }

  func retryADBServer() {
    deviceManager.retryADBServer()
  }

  func enqueue(_ command: SnapOCommand) {
    guard !isTornDown else { return }
    // Reserve startup before the asynchronous command can yield to device discovery.
    hasStartedInitialCapture = true
    Task { await perform(command) }
  }

  func perform(_ command: SnapOCommand) async {
    guard !isTornDown else { return }
    hasStartedInitialCapture = true
    if command != .livepreview, startupPreparation.isAvailable {
      await startupPreparation.discard()
      guard !isTornDown, !Task.isCancelled else { return }
    }
    if command != .livepreview, let activity = captureCoordinator.captureActivity {
      lastError = CaptureCoordinationError.captureBusy(activity).localizedDescription
      return
    }
    // Preview devices may still be booting and cannot capture yet.
    guard hasDevices, command == .livepreview || !usesPreviewDeviceStream else {
      pendingCommands.append(command)
      let usePreview = pendingCommands.first == .livepreview
      if deviceStreamTask != nil, usePreview != usesPreviewDeviceStream {
        observeDevices(usePreview: usePreview)
      }
      return
    }
    switch command {
    case .record:
      await startRecording()
    case .capture:
      await captureScreenshots()
    case .livepreview:
      guard canStartLivePreviewNow else { return }
      await startLivePreview()
    }
  }

  func selectMedia(id: CaptureMedia.ID) {
    selectMedia(id: Optional(id))
  }

  func selectMedia(id: CaptureMedia.ID?) {
    deviceOpenRequest = nil
    pendingPreferredDeviceID = nil
    snapshotController.selectMedia(id: id)
  }

  func selectNextMedia() {
    deviceOpenRequest = nil
    pendingPreferredDeviceID = nil
    snapshotController.selectNextMedia()
  }

  func selectPreviousMedia() {
    deviceOpenRequest = nil
    pendingPreferredDeviceID = nil
    snapshotController.selectPreviousMedia()
  }

  func selectDevice(id: String) {
    guard pendingPreferredDeviceID != id else { return }
    if currentCapture?.device.id == id {
      pendingPreferredDeviceID = nil
      return
    }
    mediaDisplayMode.updateLastViewedDeviceID(id)
    if let media = mediaList.first(where: { $0.device.id == id }) {
      pendingPreferredDeviceID = nil
      mediaDisplayMode.selectMedia(id: media.id)
    } else {
      pendingPreferredDeviceID = id
      mediaDisplayMode.clearSelection()
    }
  }

  func hasAlternativeMedia() -> Bool {
    snapshotController.hasAlternativeMedia
  }

  func synchronizeCaptureHistory(availableCaptureIDs: Set<UUID>, root: URL) {
    guard !isTornDown, !isProcessing, case .displaying = mode else { return }
    let remaining = mediaList.filter { capture in
      guard let url = capture.media.url,
            url.deletingLastPathComponent().deletingLastPathComponent().path == root.path else { return true }
      return availableCaptureIDs.contains(capture.id)
    }
    guard remaining.count != mediaList.count else { return }
    let deletedCurrentCapture = currentCapture.map { current in
      !remaining.contains { $0.id == current.id }
    } ?? remaining.isEmpty
    if deletedCurrentCapture {
      mediaDisplayMode.updateMediaList([], preserveDeviceID: nil, shouldSort: false)
      mode = .idle
      lastError = nil
      screenshotFailures = []
      Task { await startLivePreview() }
    } else {
      mediaDisplayMode.updateMediaList(remaining, preserveDeviceID: nil, shouldSort: false)
    }
  }

  func dismissScreenshotFailures() {
    screenshotFailures = []
    lastError = nil
  }

  var hasDevices: Bool {
    !knownDevices.isEmpty
  }

  var isRecording: Bool {
    recordingMode != nil
  }

  var shouldFloatRecordingWindow: Bool {
    isRecording && !isProcessing && !isLivePreviewActive
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

  private var canChangeCapture: Bool {
    !isTornDown && !isProcessing && !isSavingReview && !isRecording && !isStoppingLivePreview && hasDevices
  }

  var canCaptureNow: Bool {
    canChangeCapture && !captureCoordinator.isCapturing
  }

  var captureUnavailableReason: String? {
    captureCoordinator.captureActivity.map { CaptureCoordinationError.captureBusy($0).localizedDescription }
  }

  var isReviewingCapture: Bool {
    guard case .displaying = mode else { return false }
    return !isRecording && !mediaList.isEmpty
  }

  func finishCaptureReview() async {
    guard isReviewingCapture else { return }
    reviewCrops = [:]
    mediaDisplayMode.updateMediaList([], preserveDeviceID: nil, shouldSort: false)
    mode = .idle
    lastError = nil
    screenshotFailures = []
    await startLivePreview()
  }

  private func prepareToLeaveReview() {
    guard isReviewingCapture else { return }
    fileStore.discardPreviews(mediaList)
    reviewCrops = [:]
    mediaDisplayMode.updateMediaList([], preserveDeviceID: nil, shouldSort: false)
    mode = .idle
  }

  var canStartRecordingNow: Bool {
    canCaptureNow
  }

  var canStartLivePreviewNow: Bool {
    canChangeCapture && !isLivePreviewActive
  }

  var canSelectLivePreview: Bool {
    !isStoppingLivePreview && (isLivePreviewActive || canStartLivePreviewNow)
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

  func captureScreenshots(useStartupPreparation: Bool = false) async {
    if !useStartupPreparation {
      guard await waitForInitialCaptureSetup() else { return }
    }
    guard canChangeCapture else { return }
    let preloadedTask = useStartupPreparation ? startupPreparation.claimScreenshots(for: knownDevices) : nil
    guard preloadedTask != nil || !captureCoordinator.isCapturing else {
      lastError = captureUnavailableReason
      return
    }
    prepareToLeaveReview()
    hasStartedInitialCapture = true
    isProcessing = true
    if preloadedTask == nil { await startupPreparation.discard() }
    guard !isTornDown else {
      preloadedTask?.cancel()
      return
    }
    guard await stopLivePreviewForCapture() else {
      preloadedTask?.cancel()
      return
    }
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
      devices: knownDevices,
      preloadedTask: preloadedTask
    ) { [weak self] result in
      guard let self, !isTornDown else { return }
      applyScreenshotCaptureResult(result)
    }
    mode = .preparingScreenshot(screenshotMode)
    screenshotMode.start()
  }

  func startRecording() async {
    guard await waitForInitialCaptureSetup(), canChangeCapture else { return }
    guard !captureCoordinator.isCapturing else {
      lastError = captureUnavailableReason
      return
    }
    prepareToLeaveReview()
    hasStartedInitialCapture = true
    let recordsBugReport = AppSettings.shared.recordAsBugReport
    let needsPreview = !isLivePreviewActive && !recordsBugReport
    guard !isTornDown, !Task.isCancelled else { return }
    isProcessing = true
    await startupPreparation.discard()
    guard !isTornDown else { return }
    guard hasDevices else { isProcessing = false
      return
    }
    if recordsBugReport {
      guard await stopLivePreviewForCapture() else { return }
      mediaDisplayMode.updateMediaList([], preserveDeviceID: nil, shouldSort: false)
    }
    let devices = knownDevices
    lastError = nil
    screenshotFailures = []
    let recordingMode = RecordingMode(
      recordingService: recordingService,
      devices: devices,
      options: RecordingOptions(
        recordsBugReport: recordsBugReport,
        showsTouches: AppSettings.shared.showTouchesDuringCapture
      )
    ) { [weak self] result in
      await self?.completeRecording(result)
    }
    self.recordingMode = recordingMode
    recordingMode.start()
    isProcessing = false
    if needsPreview { Task { await self.startLivePreview(allowRecording: true) } }
  }

  private func completeRecording(_ result: RecordingMode.Result) async {
    guard !isTornDown else { return }
    isFinishingRecording = true
    isProcessing = true
    if case .completed(let media, _) = result, !media.isEmpty,
       case .livePreview(let preview) = mode {
      pendingPreferredDeviceID = currentCapture?.device.id ?? lastViewedDeviceID
      await preview.stop()
      guard !isTornDown else { return }
      mode = .idle
    }
    recordingMode = nil
    isFinishingRecording = false
    isProcessing = false
    switch result {
    case .failed(let error):
      lastError = error.localizedDescription
      if !isLivePreviewActive { mode = .idle }
    case .completed(let media, let error):
      if media.isEmpty, isLivePreviewActive {
        lastError = error?.localizedDescription
      } else {
        applyCaptureResults(newMedia: media, encounteredError: error)
      }
    }
  }

  func stopRecording() async {
    guard isRecording, !isFinishingRecording else { return }
    guard let recordingMode else { return }

    isProcessing = true
    lastError = nil
    screenshotFailures = []

    isFinishingRecording = true
    await recordingMode.finish()
  }

  var loadingPreviewDeviceID: String? {
    pendingPreferredDeviceID ?? selectedDeviceID ?? knownDevices.first?.id
  }

  func showLivePreview(deviceID: String) async {
    guard !isTornDown, !Task.isCancelled else { return }
    let request = deviceOpenRequest
    if !usesPreviewDeviceStream {
      hasStartedInitialCapture = true
      observeDevices(usePreview: true)
    }
    let deadline = Date().addingTimeInterval(20)
    while !isTornDown, !Task.isCancelled, deviceOpenRequest == request, Date() < deadline {
      if isLivePreviewActive, !isStoppingLivePreview, !isFinishingRecording,
         knownDevices.contains(where: { $0.id == deviceID }) {
        selectDevice(id: deviceID)
        return
      }
      if !isProcessing, knownDevices.contains(where: { $0.id == deviceID }) {
        await startLivePreview(preferredDeviceID: deviceID)
        guard isLivePreviewActive, !Task.isCancelled, deviceOpenRequest == request else { return }
        selectDevice(id: deviceID)
        return
      }
      do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
    }
    if !isTornDown, !Task.isCancelled, deviceOpenRequest == request {
      lastError = "The emulator is not available for Live Preview yet. Try again shortly."
    }
  }

  private var restoredDeviceID: String? {
    let id = AppSettings.shared.lastViewedDeviceID
    return knownDevices.first { $0.id == id }?.id
  }

  func startLivePreview(useStartupPreparation: Bool = false, preferredDeviceID: String? = nil, allowRecording: Bool = false) async {
    guard canStartLivePreviewNow || (allowRecording && isRecording && !isLivePreviewActive && !isTornDown) else { return }
    prepareToLeaveReview()
    hasStartedInitialCapture = true
    isProcessing = true
    lastError = nil
    screenshotFailures = []
    let preferredDeviceID = preferredDeviceID ?? pendingPreferredDeviceID ?? currentCapture?.device
      .id ?? lastViewedDeviceID ?? restoredDeviceID ?? knownDevices
      .first?.id
    #if PERF_TRACING
    Perf.startupEvent("startup selected device", deviceID: preferredDeviceID)
    #endif
    pendingPreferredDeviceID = preferredDeviceID
    let options = LivePreviewOptions(showsTouches: AppSettings.shared.showTouchesDuringCapture)
    let prepared: PreparedLivePreview? = if useStartupPreparation, let device = knownDevices.first(where: { $0.id == preferredDeviceID }) {
      await startupPreparation.claimLivePreview(for: device, options: options)
    } else {
      nil
    }
    if prepared == nil { await startupPreparation.discard() }
    guard !isTornDown else {
      await prepared?.discard()
      return
    }

    let livePreviewMode = LivePreviewMode(
      livePreviewService: livePreviewService,
      adbService: adbService,
      options: options,
      preparedLivePreview: prepared,
      mediaDisplayMode: mediaDisplayMode,
      preferredDeviceIDProvider: { [weak self] in
        guard let self else { return nil }
        return pendingPreferredDeviceID ?? selectedDeviceID
      },
      onMediaApplied: { [weak self] in
        guard let self, !isTornDown, !isStoppingLivePreview else { return }
        isProcessing = isFinishingRecording
        if let pending = pendingPreferredDeviceID, mediaList.contains(where: { $0.device.id == pending }) {
          pendingPreferredDeviceID = nil
        }
        resumeInitialCaptureWaiters()
      }
    )
    mode = .livePreview(livePreviewMode)
    await livePreviewMode.start(with: knownDevices)
    guard !isTornDown, !livePreviewMode.isStopping,
          case .livePreview(let currentMode) = mode, currentMode === livePreviewMode else { return }
    isProcessing = isFinishingRecording
  }

  private func stopLivePreviewForCapture() async -> Bool {
    guard case .livePreview(let livePreviewMode) = mode else { return !isTornDown && !Task.isCancelled }
    let preferredDeviceID = currentCapture?.device.id ?? lastViewedDeviceID
    await livePreviewMode.stop()
    guard !isTornDown,
          case .livePreview(let currentMode) = mode, currentMode === livePreviewMode else { return false }
    pendingPreferredDeviceID = preferredDeviceID
    if let preferredDeviceID { mediaDisplayMode.updateLastViewedDeviceID(preferredDeviceID) }
    mode = .idle
    guard hasDevices, !Task.isCancelled else {
      isProcessing = false
      pendingPreferredDeviceID = nil
      return false
    }
    return true
  }

  func tearDown() async {
    guard !isTornDown else { return }
    isTornDown = true
    pendingCommands.removeAll()
    deviceOpenRequest = nil
    initialCaptureTask?.cancel()
    initialCaptureTask = nil
    resumeInitialCaptureWaiters()
    deviceStreamTask?.cancel()
    deviceStreamTask = nil

    let activeMode = mode
    mode = .idle
    pendingPreferredDeviceID = nil
    if case .preparingScreenshot(let screenshotMode) = activeMode {
      await screenshotMode.cancel()
    }
    if let recordingMode {
      self.recordingMode = nil
      await recordingMode.cancel()
    }
    if case .livePreview(let livePreviewMode) = activeMode {
      await livePreviewMode.stop()
    }
    hasStartedInitialCapture = false
    mediaDisplayMode.tearDown()
  }

  func copyCurrentImage(to pasteboard: NSPasteboard = .general) {
    guard let capture = currentCapture,
          case .image(let url, _) = capture.media,
          var image = NSImage(contentsOf: url)
    else { return }
    if let crop = reviewCrops[capture.id], crop != CaptureCropGeometry.fullImage {
      guard let source = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
            let cropped = source.cropping(to: CaptureCropGeometry.frame(
              for: crop, in: CGRect(x: 0, y: 0, width: source.width, height: source.height)
            ).integral) else { return }
      image = NSImage(cgImage: cropped, size: CGSize(width: cropped.width, height: cropped.height))
    }
    pasteboard.clearContents()
    if pasteboard.writeObjects([image]) {
      imageCopied()
    }
  }

  func imageCopied() {
    imageCopyID = UUID()
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
      startCaptureIfNeeded()
    }
    Task { @MainActor [weak self] in
      guard let self else { return }
      if let recordingMode {
        await recordingMode.updateDevices(devices)
      }
      if case .livePreview(let livePreviewMode) = mode {
        await livePreviewMode.updateDevices(devices)
      }
    }
  }

  private func startCaptureIfNeeded() {
    if !pendingCommands.isEmpty {
      let commands = pendingCommands
      pendingCommands.removeAll()
      // Reserve startup before yielding so later device updates cannot start the default.
      hasStartedInitialCapture = true
      Task { [weak self] in
        for command in commands {
          await self?.perform(command)
        }
      }
      return
    }

    guard deviceOpenRequest == nil, !hasStartedInitialCapture, mediaList.isEmpty, case .idle = mode else { return }
    hasStartedInitialCapture = true
    initialCaptureTask = Task { [weak self] in
      guard let self else { return }
      defer {
        if !Task.isCancelled {
          initialCaptureTask = nil
          resumeInitialCaptureWaiters()
        }
      }
      guard !Task.isCancelled, !isTornDown, case .idle = mode else { return }
      switch AppSettings.shared.startupCaptureMode {
      case .livePreview: await startLivePreview(useStartupPreparation: true)
      case .screenshot: await captureScreenshots(useStartupPreparation: true)
      }
    }
  }

  private func waitForInitialCaptureSetup() async -> Bool {
    guard let task = initialCaptureTask else { return !Task.isCancelled }
    // Preview readiness can unblock captures before all startup display queries finish.
    let id = UUID()
    await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        if Task.isCancelled {
          continuation.resume()
        } else {
          initialCaptureWaiters[id] = continuation
        }
      }
    } onCancel: {
      Task { @MainActor [weak self] in
        self?.initialCaptureWaiters.removeValue(forKey: id)?.resume()
      }
    }
    return !task.isCancelled && !Task.isCancelled
  }

  private func resumeInitialCaptureWaiters() {
    let waiters = initialCaptureWaiters.values
    initialCaptureWaiters.removeAll()
    for waiter in waiters {
      waiter.resume()
    }
  }

  func livePreviewConnection(for deviceID: String) -> LivePreviewConnection? {
    guard case .livePreview(let livePreviewMode) = mode else { return nil }
    return livePreviewMode.connection(for: deviceID)
  }

  func canReconnectLivePreview(for deviceID: String) -> Bool {
    !isTornDown && isLivePreviewActive && !isStoppingLivePreview && knownDevices.contains { $0.id == deviceID }
  }

  func startLivePreviewStream(for deviceID: String) async -> LivePreviewRenderer? {
    guard case .livePreview(let livePreviewMode) = mode else { return nil }
    guard !livePreviewMode.isStopping else { return nil }
    do {
      let renderer = try await livePreviewMode.makeRenderer(for: deviceID)
      guard case .livePreview(let currentMode) = mode,
            currentMode === livePreviewMode,
            !currentMode.isStopping else {
        await livePreviewMode.stopRenderer(renderer)
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

  func livePreviewScreenshot(for deviceID: String) async throws -> Data {
    let exec = await adbService.exec()
    return try await exec.screencapPNG(deviceID: deviceID)
  }

  func sendLivePreviewKey(_ key: String, deviceID: String) async throws {
    let exec = await adbService.exec()
    let output = try await exec.keyEvent(deviceID: deviceID, keyCode: key)
    guard output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw ADBError.protocolFailure("Device input failed")
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
