import AppKit
import Combine
import Foundation
import SwiftUI

@MainActor
final class CaptureWindowController: ObservableObject {
  private let captureService: CaptureService
  private let deviceTracker: DeviceTracker
  private let adbService: ADBService
  let fileStore: FileStore

  let snapshotController = CaptureSnapshotController()
  let mediaDisplayMode: MediaDisplayMode

  @Published private(set) var isDeviceListInitialized: Bool = false
  @Published private(set) var isProcessing: Bool = false
  @Published private(set) var isRecording: Bool = false
  @Published private(set) var isLivePreviewActive: Bool = false
  @Published private(set) var isStoppingLivePreview: Bool = false
  @Published private(set) var lastError: String?
  @Published private(set) var mode: CaptureWindowMode

  private var knownDevices: [Device] = []
  private var deviceStreamTask: Task<Void, Never>?
  private var livePreviewManager: LivePreviewManager?
  private var pendingPreferredDeviceID: String?
  private var isPreloadConsumptionActive = false
  private var hasAttemptedInitialPreload = false
  private var snapshotCancellable: AnyCancellable?

  init(
    captureService: CaptureService,
    deviceTracker: DeviceTracker,
    fileStore: FileStore,
    adbService: ADBService
  ) {
    self.captureService = captureService
    self.deviceTracker = deviceTracker
    self.fileStore = fileStore
    self.adbService = adbService
    self.mediaDisplayMode = MediaDisplayMode(snapshotController: snapshotController)
    self.mode = .idle
    snapshotCancellable = snapshotController.objectWillChange
      .sink { [weak self] _ in self?.objectWillChange.send() }
  }

  func start() async {
    deviceStreamTask?.cancel()
    let tracker = deviceTracker
    isDeviceListInitialized = tracker.latestDevices.isEmpty ? false : true

    deviceStreamTask = Task { [weak self] in
      guard let self else { return }
      for await devices in tracker.deviceStream() {
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

  func hasAlternativeMedia() -> Bool {
    snapshotController.hasAlternativeMedia
  }

  var hasDevices: Bool { !knownDevices.isEmpty }

  var canCaptureNow: Bool { !isProcessing && !isRecording && !isLivePreviewActive && hasDevices }
  var canStartRecordingNow: Bool { !isProcessing && !isRecording && !isLivePreviewActive && hasDevices }
  var canStartLivePreviewNow: Bool { !isProcessing && !isRecording && !isLivePreviewActive && hasDevices }

  var mediaList: [CaptureMedia] { mediaDisplayMode.mediaList }
  var selectedMediaID: CaptureMedia.ID? { mediaDisplayMode.selectedMediaID }
  var currentCaptureViewID: UUID? { mediaDisplayMode.currentCaptureViewID }
  var shouldShowPreviewHint: Bool { mediaDisplayMode.shouldShowPreviewHint }
  var overlayMediaList: [CaptureMedia] { mediaDisplayMode.overlayMediaList }
  var lastViewedDeviceID: String? { mediaDisplayMode.lastViewedDeviceID }

  var currentCapture: CaptureMedia? { mediaDisplayMode.currentCapture }

  var navigationTitle: String {
    currentCapture?.device.displayTitle ?? "Snap-O"
  }

  var currentCaptureDeviceTitle: String? {
    currentCapture?.device.displayTitle
  }

  var captureProgressText: String? { mediaDisplayMode.captureProgressText }

  var displayInfoForSizing: DisplayInfo? {
    if isRecording {
      return mediaDisplayMode.lastPreviewDisplayInfo ?? currentCapture?.media.common.display
    }
    return currentCapture?.media.common.display
  }

  func captureScreenshots() async {
    guard canCaptureNow else { return }
    isProcessing = true
    lastError = nil
    if pendingPreferredDeviceID == nil {
      pendingPreferredDeviceID = currentCapture?.device.id ?? lastViewedDeviceID
    }
    mediaDisplayMode.updateMediaList(
      [],
      preserveDeviceID: nil,
      shouldSort: false
    )

    let screenshotMode = PreparingScreenshotMode(
      captureService: captureService
    ) { [weak self] media, error in
      guard let self else { return }
      self.applyCaptureResults(newMedia: media, encounteredError: error)
    }
    mode = .preparingScreenshot(screenshotMode)
    screenshotMode.start()
  }

  func startRecording() async {
    guard canStartRecordingNow else { return }
    let devices = knownDevices
    isProcessing = true
    lastError = nil
    pendingPreferredDeviceID = currentCapture?.device.id
    mediaDisplayMode.updateMediaList(
      [],
      preserveDeviceID: nil,
      shouldSort: false
    )
    let recordingMode = RecordingMode(
      captureService: captureService,
      devices: devices
    ) { [weak self] result in
      guard let self else { return }
      self.isRecording = false
      self.isProcessing = false
      switch result {
      case .failed(let error):
        self.lastError = error.localizedDescription
        self.mode = .idle
      case .completed(let media, let error):
        if error == nil, media.isEmpty {
          self.mode = .idle
          Task { await self.captureScreenshots() }
        } else {
          self.applyCaptureResults(newMedia: media, encounteredError: error)
        }
      }
    }
    mode = .recording(recordingMode)
    isRecording = true
    recordingMode.start()
    isProcessing = false
  }

  func stopRecording() async {
    guard isRecording else { return }
    guard case .recording(let recordingMode) = mode else { return }
    let devices = knownDevices
    guard !devices.isEmpty else {
      isRecording = false
      mode = .idle
      return
    }

    isProcessing = true
    lastError = nil

    await recordingMode.finish(using: devices)
  }

  func startLivePreview() async {
    guard canStartLivePreviewNow else { return }
    isProcessing = true
    lastError = nil
    let preferredDeviceID = currentCapture?.device.id ?? lastViewedDeviceID ?? knownDevices.first?.id
    pendingPreferredDeviceID = preferredDeviceID

    let manager = LivePreviewManager(
      captureService: captureService,
      adbService: adbService
    ) { [weak self] media in
      guard let self else { return }
      handleLivePreviewMediaUpdate(media)
    }
    livePreviewManager?.stop()
    livePreviewManager = manager
    isLivePreviewActive = true
    await manager.start(with: knownDevices)
  }

  func stopLivePreview() async {
    guard isLivePreviewActive, !isStoppingLivePreview else { return }
    isStoppingLivePreview = true
    let preferredDeviceID = currentCapture?.device.id ?? lastViewedDeviceID
    livePreviewManager?.stop()
    livePreviewManager = nil
    isLivePreviewActive = false
    pendingPreferredDeviceID = preferredDeviceID
    if let preferredDeviceID { mediaDisplayMode.updateLastViewedDeviceID(preferredDeviceID) }
    isStoppingLivePreview = false
    if !hasDevices {
      isProcessing = false
      pendingPreferredDeviceID = nil
      return
    }
    if isProcessing { isProcessing = false }
    await captureScreenshots()
  }

  func tearDown() {
    deviceStreamTask?.cancel()
    deviceStreamTask = nil

    livePreviewManager?.stop()
    livePreviewManager = nil
    isLivePreviewActive = false
    isStoppingLivePreview = false
    pendingPreferredDeviceID = nil
    if case .preparingScreenshot(let screenshotMode) = mode {
      screenshotMode.cancel()
    }
    if case .checkingPreload(let preloadMode) = mode {
      preloadMode.cancel()
    }
    if case .recording(let recordingMode) = mode {
      recordingMode.cancel()
    }
    isPreloadConsumptionActive = false
    hasAttemptedInitialPreload = false
    mediaDisplayMode.tearDown()
    mode = .idle
  }

  func copyCurrentImage() {
    guard let capture = currentCapture,
          case .image(let url, _) = capture.media,
          let image = NSImage(contentsOf: url)
    else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.writeObjects([image])
  }

  private func collectMedia(
    for devices: [Device],
    action: @Sendable @escaping (Device) async throws -> CaptureMedia?
  ) async -> ([CaptureMedia], Error?) {
    var newMedia: [CaptureMedia] = []
    var encounteredError: Error?

    await withTaskGroup(of: Result<CaptureMedia?, Error>.self) { group in
      for device in devices {
        group.addTask {
          do {
            return try await .success(action(device))
          } catch {
            return .failure(error)
          }
        }
      }

      for await result in group {
        switch result {
        case .success(let media):
          if let media {
            newMedia.append(media)
          }
        case .failure(let error):
          encounteredError = error
        }
      }
    }

    return (newMedia, encounteredError)
  }

  private func applyPreloadedMedia(_ mediaList: [CaptureMedia]) {
    mediaDisplayMode.updateMediaList(
      mediaList,
      preserveDeviceID: mediaList.first?.device.id,
      shouldSort: false
    )
    mode = .displaying(mediaDisplayMode)
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
    knownDevices = devices
    if mediaList.isEmpty {
      mediaDisplayMode.clearSelection()
    }
    Task.detached(priority: .utility) { [weak self] in
      guard let self else { return }
      await captureService.preloadScreenshots()
    }
    if !devices.isEmpty {
      startPreloadConsumptionIfNeeded()
    }
    Task { @MainActor [weak self] in
      await self?.livePreviewManager?.updateDevices(devices)
    }
  }

  private func startPreloadConsumptionIfNeeded() {
    guard !isPreloadConsumptionActive else { return }
    guard !hasAttemptedInitialPreload else { return }
    guard mediaList.isEmpty else { return }
    isPreloadConsumptionActive = true
    hasAttemptedInitialPreload = true
    let preloadMode = CheckPreloadMode(
      captureService: captureService
    ) { [weak self] outcome in
      guard let self else { return }
      self.isPreloadConsumptionActive = false
      switch outcome {
      case .found(let media):
        self.applyPreloadedMedia(media)
        self.isProcessing = false
      case .missing:
        Task { [weak self] in
          await self?.captureScreenshots()
        }
      }
    }
    mode = .checkingPreload(preloadMode)
    preloadMode.start()
  }

  private func handleLivePreviewMediaUpdate(_ media: [CaptureMedia]) {
    let preferredDeviceID: String? = if let pendingPreferredDeviceID {
      pendingPreferredDeviceID
    } else if let currentID = selectedMediaID,
              let current = mediaList.first(where: { $0.id == currentID }) {
      current.device.id
    } else {
      nil
    }

    mediaDisplayMode.updateMediaList(
      media,
      preserveDeviceID: preferredDeviceID,
      shouldSort: false
    )

    isProcessing = false
    pendingPreferredDeviceID = nil
  }

  func startLivePreviewStream(for deviceID: String) async -> LivePreviewRenderer? {
    guard let livePreviewManager else { return nil }
    do {
      return try await livePreviewManager.makeRenderer(for: deviceID)
    } catch {
      lastError = error.localizedDescription
      return nil
    }
  }

  func stopLivePreviewStream(_ renderer: LivePreviewRenderer) async {
    if let livePreviewManager {
      await livePreviewManager.stopRenderer(renderer)
    } else {
      renderer.session.cancel()
      _ = await renderer.session.waitUntilStop()
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
