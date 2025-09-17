import AppKit
import Combine
import Foundation
import SwiftUI

@MainActor
final class CaptureWindowController: ObservableObject {
  private let services: AppServices

  @Published private(set) var mediaList: [CaptureMedia] = []
  @Published private(set) var selectedMediaID: CaptureMedia.ID?
  @Published private(set) var transitionDirection: DeviceTransitionDirection = .neutral
  @Published private(set) var isDeviceListInitialized: Bool = false
  @Published private(set) var isProcessing: Bool = false
  @Published private(set) var isRecording: Bool = false
  @Published private(set) var isLivePreviewActive: Bool = false
  @Published private(set) var isStoppingLivePreview: Bool = false
  @Published private(set) var lastError: String?
  @Published private(set) var currentCaptureViewID: UUID?
  @Published private(set) var shouldShowPreviewHint: Bool = false
  @Published private(set) var overlayMediaList: [CaptureMedia] = []

  private var knownDevices: [Device] = []
  private var recordingSessions: [String: RecordingSession] = [:]
  private var deviceStreamTask: Task<Void, Never>?
  private var livePreviewManager: LivePreviewManager?
  private var pendingPreferredDeviceID: String?
  private var preloadConsumptionTask: Task<Void, Never>?
  private var hasAttemptedPreloadConsumption = false
  private var currentCaptureSnapshot: CaptureMedia?
  private var currentCaptureSource: CaptureMedia?
  private var lastViewedDeviceID: String?
  private var previewHintTask: Task<Void, Never>?
  private var isPreviewHintHovered: Bool = false
  private var lastPreviewDisplayInfo: DisplayInfo?

  init(services: AppServices = .shared) {
    self.services = services
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

  func selectMedia(id: CaptureMedia.ID?, direction: DeviceTransitionDirection) {
    guard selectedMediaID != id else {
      transitionDirection = direction
      return
    }

    transitionDirection = direction
    Task { @MainActor [weak self] in
      await Task.yield()
      guard let self else { return }
      selectedMediaID = id
      let baseCapture = capture(for: id) ?? mediaList.first
      updateCurrentCaptureSnapshotIfNeeded(with: baseCapture)
      await showPreviewHintIfNeeded(transient: true)
    }
  }

  func selectNextMedia() {
    guard !mediaList.isEmpty else { return }
    guard let currentID = selectedMediaID,
          let currentIndex = mediaList.firstIndex(where: { $0.id == currentID })
    else {
      selectMedia(id: mediaList.first?.id, direction: .next)
      return
    }
    let nextIndex = (currentIndex + 1) % mediaList.count
    selectMedia(id: mediaList[nextIndex].id, direction: .next)
  }

  func selectPreviousMedia() {
    guard !mediaList.isEmpty else { return }
    guard let currentID = selectedMediaID,
          let currentIndex = mediaList.firstIndex(where: { $0.id == currentID })
    else {
      selectMedia(id: mediaList.first?.id, direction: .previous)
      return
    }
    let previousIndex = (currentIndex - 1 + mediaList.count) % mediaList.count
    selectMedia(id: mediaList[previousIndex].id, direction: .previous)
  }

  func hasAlternativeMedia() -> Bool {
    mediaList.count > 1
  }

  var hasDevices: Bool { !knownDevices.isEmpty }

  var canCaptureNow: Bool { !isProcessing && !isRecording && !isLivePreviewActive && hasDevices }
  var canStartRecordingNow: Bool { !isProcessing && !isRecording && !isLivePreviewActive && hasDevices }
  var canStartLivePreviewNow: Bool { !isProcessing && !isRecording && !isLivePreviewActive && hasDevices }

  var currentCapture: CaptureMedia? { currentCaptureSnapshot }

  var navigationTitle: String {
    currentCapture?.device.displayTitle ?? "Snap-O"
  }

  var currentCaptureDeviceTitle: String? {
    currentCapture?.device.displayTitle
  }

  var captureProgressText: String? {
    guard mediaList.count > 1,
          let selectedID = selectedMediaID,
          let index = mediaList.firstIndex(where: { $0.id == selectedID })
    else { return nil }
    return "\(index + 1)/\(mediaList.count)"
  }

  var displayInfoForSizing: DisplayInfo? {
    if isRecording {
      return lastPreviewDisplayInfo ?? currentCapture?.media.common.display
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
    updateMediaList([], preserveDeviceID: nil, shouldSort: false, resetTransition: true)

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
    updateMediaList([], preserveDeviceID: nil, shouldSort: false, resetTransition: true)

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
    if let preferredDeviceID { lastViewedDeviceID = preferredDeviceID }
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
    previewHintTask?.cancel()
    previewHintTask = nil
    shouldShowPreviewHint = false
    preloadConsumptionTask?.cancel()
    preloadConsumptionTask = nil
    hasAttemptedPreloadConsumption = false
    overlayMediaList = []
    lastPreviewDisplayInfo = nil
    lastPreviewDisplayInfo = nil
  }

  func copyCurrentImage() {
    guard let capture = currentCapture,
          case .image(let url, _) = capture.media,
          let image = NSImage(contentsOf: url)
    else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.writeObjects([image])
  }

  private func updateCurrentCaptureSnapshotIfNeeded(with baseCapture: CaptureMedia?) {
    guard let baseCapture else {
      currentCaptureSnapshot = nil
      currentCaptureSource = nil
      currentCaptureViewID = nil
      lastPreviewDisplayInfo = nil
      return
    }

    let didChangeCapture = currentCaptureSource?.id != baseCapture.id

    currentCaptureSnapshot = baseCapture
    currentCaptureSource = baseCapture
    lastPreviewDisplayInfo = baseCapture.media.common.display

    if didChangeCapture {
      currentCaptureViewID = UUID()
    }
    lastViewedDeviceID = baseCapture.device.id
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
    updateMediaList(
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
      updateMediaList(
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
      selectedMediaID = nil
      updateCurrentCaptureSnapshotIfNeeded(with: nil)
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
        await self.captureScreenshots()
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

    updateMediaList(
      media,
      preserveDeviceID: preferredDeviceID,
      shouldSort: false,
      resetTransition: false
    )

    isProcessing = false
    pendingPreferredDeviceID = nil
    Task { await showPreviewHintIfNeeded(transient: true) }
  }

  private func updateMediaList(
    _ newMedia: [CaptureMedia],
    preserveDeviceID: String?,
    shouldSort: Bool,
    resetTransition: Bool
  ) {
    if shouldShowPreviewHint {
      dismissPreviewHintImmediately()
    }

    var ordered = shouldSort ? newMedia.sorted { $0.device.displayTitle < $1.device.displayTitle } : newMedia

    if let preserve = preserveDeviceID,
       let index = ordered.firstIndex(where: { $0.device.id == preserve }),
       index != ordered.startIndex {
      let preferred = ordered.remove(at: index)
      ordered.insert(preferred, at: ordered.startIndex)
    }

    mediaList = ordered

    if ordered.isEmpty {
      selectedMediaID = nil
    } else if let preserve = preserveDeviceID,
              let preserved = ordered.first(where: { $0.device.id == preserve }) {
      selectedMediaID = preserved.id
    } else if let currentID = selectedMediaID,
              ordered.contains(where: { $0.id == currentID }) {
      // Keep current selection
    } else {
      selectedMediaID = ordered.first?.id
    }

    if resetTransition {
      transitionDirection = .neutral
    }

    let baseCapture: CaptureMedia? = if let currentID = selectedMediaID {
      ordered.first { $0.id == currentID }
    } else {
      ordered.first
    }
    updateCurrentCaptureSnapshotIfNeeded(with: baseCapture)
    Task { await showPreviewHintIfNeeded(transient: true) }
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

  private func capture(for id: CaptureMedia.ID?) -> CaptureMedia? {
    guard let id else { return nil }
    return mediaList.first { $0.id == id }
  }

  private func showPreviewHintIfNeeded(transient: Bool) async {
    await Task.yield()

    guard mediaList.count > 1 else {
      shouldShowPreviewHint = false
      previewHintTask?.cancel()
      previewHintTask = nil
      isPreviewHintHovered = false
      overlayMediaList = []
      return
    }

    previewHintTask?.cancel()
    previewHintTask = nil

    overlayMediaList = mediaList
    shouldShowPreviewHint = true

    guard transient else { return }
    schedulePreviewHintDismiss(after: 2)
  }

  func setPreviewHintHovering(_ isHovering: Bool) {
    if isHovering {
      isPreviewHintHovered = true
      previewHintTask?.cancel()
      previewHintTask = nil
    } else {
      isPreviewHintHovered = false
      if shouldShowPreviewHint {
        schedulePreviewHintDismiss(after: 0.5)
      }
    }
  }

  func setProgressHovering(_ isHovering: Bool) {
    if isHovering {
      setPreviewHintHovering(true)
      Task { await showPreviewHintIfNeeded(transient: false) }
    } else {
      setPreviewHintHovering(false)
    }
  }

  private func schedulePreviewHintDismiss(after seconds: Double) {
    previewHintTask?.cancel()
    previewHintTask = Task { [weak self] in
      let delay = UInt64(seconds * 1_000_000_000)
      try? await Task.sleep(nanoseconds: delay)
      guard !Task.isCancelled else { return }
      await MainActor.run {
        guard let self, !self.isPreviewHintHovered else { return }
        self.shouldShowPreviewHint = false
        self.overlayMediaList = []
        self.previewHintTask = nil
      }
    }
  }

  private func dismissPreviewHintImmediately() {
    previewHintTask?.cancel()
    previewHintTask = nil
    shouldShowPreviewHint = false
    isPreviewHintHovered = false
    overlayMediaList = []
  }
}
