import AppKit
import Combine
import Foundation
import SwiftUI

@MainActor
final class CaptureWindowController: ObservableObject {
  private let services: AppServices

  let snapshotController = CaptureSnapshotController()

  @Published private(set) var isDeviceListInitialized: Bool = false
  @Published private(set) var isProcessing: Bool = false
  @Published private(set) var isRecording: Bool = false
  @Published private(set) var isLivePreviewActive: Bool = false
  @Published private(set) var isStoppingLivePreview: Bool = false
  @Published private(set) var lastError: String?

  private var knownDevices: [Device] = []
  private var recordingSessions: [String: RecordingSession] = [:]
  private var deviceStreamTask: Task<Void, Never>?
  private var livePreviewManager: LivePreviewManager?
  private var pendingPreferredDeviceID: String?
  private var preloadConsumptionTask: Task<Void, Never>?
  private var hasAttemptedPreloadConsumption = false
  private var snapshotCancellable: AnyCancellable?

  init(services: AppServices = .shared) {
    self.services = services
    snapshotCancellable = snapshotController.objectWillChange
      .sink { [weak self] _ in self?.objectWillChange.send() }
  }

  func start() async {
    deviceStreamTask?.cancel()
    let tracker = services.deviceTracker
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

  func selectMedia(id: CaptureMedia.ID?, direction: DeviceTransitionDirection) {
    snapshotController.selectMedia(id: id, direction: direction)
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

  var mediaList: [CaptureMedia] { snapshotController.mediaList }
  var selectedMediaID: CaptureMedia.ID? { snapshotController.selectedMediaID }
  var transitionDirection: DeviceTransitionDirection { snapshotController.transitionDirection }
  var currentCaptureViewID: UUID? { snapshotController.currentCaptureViewID }
  var shouldShowPreviewHint: Bool { snapshotController.shouldShowPreviewHint }
  var overlayMediaList: [CaptureMedia] { snapshotController.overlayMediaList }
  var lastViewedDeviceID: String? { snapshotController.lastViewedDeviceID }

  var currentCapture: CaptureMedia? { snapshotController.currentCapture }

  var navigationTitle: String {
    currentCapture?.device.displayTitle ?? "Snap-O"
  }

  var currentCaptureDeviceTitle: String? {
    currentCapture?.device.displayTitle
  }

  var captureProgressText: String? { snapshotController.captureProgressText }

  var displayInfoForSizing: DisplayInfo? {
    if isRecording {
      return snapshotController.lastPreviewDisplayInfo ?? currentCapture?.media.common.display
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
    snapshotController.updateMediaList(
      [],
      preserveDeviceID: nil,
      shouldSort: false,
      resetTransition: true
    )

    if let media = await consumePreloadedMedia() {
      applyPreloadedMedia(media)
      isProcessing = false
      return
    }

    let captureService = services.captureService
    let (newMedia, encounteredError) = await captureService.captureScreenshots()

    applyCaptureResults(newMedia: newMedia, encounteredError: encounteredError)
  }

  func startRecording() async {
    guard canStartRecordingNow else { return }
    let devices = knownDevices
    isProcessing = true
    lastError = nil
    pendingPreferredDeviceID = currentCapture?.device.id
    snapshotController.updateMediaList(
      [],
      preserveDeviceID: nil,
      shouldSort: false,
      resetTransition: true
    )

    let captureService = services.captureService
    let (sessions, encounteredError) = await captureService.startRecordings(for: devices)

    if let error = encounteredError {
      lastError = error.localizedDescription
      isProcessing = false
      return
    }

    recordingSessions = sessions
    isRecording = true
    isProcessing = false
  }

  func stopRecording() async {
    guard isRecording else { return }
    let devices = knownDevices
    guard !devices.isEmpty else {
      recordingSessions.removeAll()
      isRecording = false
      return
    }

    isProcessing = true
    lastError = nil

    let captureService = services.captureService
    let (newMedia, encounteredError) = await captureService.stopRecordings(
      for: devices,
      sessions: recordingSessions
    )

    if encounteredError == nil, newMedia.isEmpty {
      recordingSessions.removeAll()
      isRecording = false
      isProcessing = false
      await captureScreenshots()
      return
    }

    applyCaptureResults(newMedia: newMedia, encounteredError: encounteredError)
    recordingSessions.removeAll()
    isRecording = false
  }

  func startLivePreview() async {
    guard canStartLivePreviewNow else { return }
    isProcessing = true
    lastError = nil
    let preferredDeviceID = currentCapture?.device.id ?? lastViewedDeviceID ?? knownDevices.first?.id
    pendingPreferredDeviceID = preferredDeviceID

    let manager = LivePreviewManager(services: services) { [weak self] media in
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
    if let preferredDeviceID { snapshotController.updateLastViewedDeviceID(preferredDeviceID) }
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
    preloadConsumptionTask?.cancel()
    preloadConsumptionTask = nil
    hasAttemptedPreloadConsumption = false
    snapshotController.tearDown()
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

  private func consumePreloadedMedia() async -> [CaptureMedia]? {
    let captureService = services.captureService

    let shouldLog = !hasAttemptedPreloadConsumption
    if shouldLog {
      Perf.step(.appFirstSnapshot, "Starting initial preview load")
      Perf.step(.appFirstSnapshot, "consume preloaded screenshot")
      hasAttemptedPreloadConsumption = true
    }

    let preloaded = await captureService.consumeAllPreloadedScreenshots()
    guard !preloaded.isEmpty else {
      if shouldLog {
        Perf.step(.appFirstSnapshot, "Preload missing; refreshing preview")
      }
      return nil
    }

    if shouldLog {
      Perf.step(.appFirstSnapshot, "Using preloaded screenshot")
    }
    return preloaded
  }

  private func applyPreloadedMedia(_ mediaList: [CaptureMedia]) {
    snapshotController.updateMediaList(
      mediaList,
      preserveDeviceID: mediaList.first?.device.id,
      shouldSort: false,
      resetTransition: true
    )
  }

  private func applyCaptureResults(
    newMedia: [CaptureMedia],
    encounteredError: Error?
  ) {
    if let error = encounteredError {
      lastError = error.localizedDescription
    }

    if !newMedia.isEmpty {
      let targetDeviceID = pendingPreferredDeviceID ?? currentCapture?.device.id
        ?? lastViewedDeviceID
      snapshotController.updateMediaList(
        newMedia,
        preserveDeviceID: targetDeviceID,
        shouldSort: true,
        resetTransition: true
      )
    }

    isProcessing = false
    pendingPreferredDeviceID = nil
  }

  private func handleDeviceUpdate(_ devices: [Device]) {
    knownDevices = devices
    if mediaList.isEmpty {
      snapshotController.clearSelection()
    }
    Task.detached(priority: .utility) { [weak self] in
      guard let self else { return }
      await services.captureService.preloadScreenshots()
    }
    if !devices.isEmpty {
      startPreloadConsumptionIfNeeded()
    }
    Task { @MainActor [weak self] in
      await self?.livePreviewManager?.updateDevices(devices)
    }
  }

  private func startPreloadConsumptionIfNeeded() {
    guard preloadConsumptionTask == nil else { return }
    guard mediaList.isEmpty else { return }
    preloadConsumptionTask = Task.detached(priority: .userInitiated) { [weak self] in
      guard let self else { return }
      if let preloaded = await consumePreloadedMedia() {
        await MainActor.run {
          self.applyPreloadedMedia(preloaded)
          self.isProcessing = false
          self.preloadConsumptionTask = nil
        }
      } else {
        await captureScreenshots()
        await MainActor.run { self.preloadConsumptionTask = nil }
      }
    }
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

    snapshotController.updateMediaList(
      media,
      preserveDeviceID: preferredDeviceID,
      shouldSort: false,
      resetTransition: false
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
    snapshotController.setPreviewHintHovering(isHovering)
  }

  func setProgressHovering(_ isHovering: Bool) {
    snapshotController.setProgressHovering(isHovering)
  }
}

extension CaptureWindowController: LivePreviewHosting {}
