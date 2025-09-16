import AppKit
import Combine
import Foundation

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

  private var knownDevices: [Device] = []
  private var recordingSessions: [String: RecordingSession] = [:]
  private var deviceStreamTask: Task<Void, Never>?
  private var livePreviewManager: LivePreviewManager?
  private var pendingPreferredDeviceID: String?
  private var preloadConsumptionTask: Task<Void, Never>?
  private var hasAttemptedPreloadConsumption = false

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
      self?.selectedMediaID = id
    }
  }

  func selectNextMedia() {
    guard !mediaList.isEmpty else { return }
    guard let currentID = selectedMediaID,
          let currentIndex = mediaList.firstIndex(where: { $0.id == currentID })
    else {
      selectMedia(id: mediaList.first?.id, direction: .down)
      return
    }
    let nextIndex = (currentIndex + 1) % mediaList.count
    selectMedia(id: mediaList[nextIndex].id, direction: .down)
  }

  func selectPreviousMedia() {
    guard !mediaList.isEmpty else { return }
    guard let currentID = selectedMediaID,
          let currentIndex = mediaList.firstIndex(where: { $0.id == currentID })
    else {
      selectMedia(id: mediaList.first?.id, direction: .up)
      return
    }
    let previousIndex = (currentIndex - 1 + mediaList.count) % mediaList.count
    selectMedia(id: mediaList[previousIndex].id, direction: .up)
  }

  func hasAlternativeMedia() -> Bool {
    mediaList.count > 1
  }

  var hasDevices: Bool { !knownDevices.isEmpty }

  var canCaptureNow: Bool { !isProcessing && !isRecording && !isLivePreviewActive && hasDevices }
  var canStartRecordingNow: Bool { !isProcessing && !isRecording && !isLivePreviewActive && hasDevices }
  var canStartLivePreviewNow: Bool { !isProcessing && !isRecording && !isLivePreviewActive && hasDevices }

  var currentCapture: CaptureMedia? {
    guard let id = selectedMediaID else { return mediaList.first }
    return mediaList.first { $0.id == id }
  }

  func captureScreenshots() async {
    guard canCaptureNow else { return }
    let devices = knownDevices

    isProcessing = true
    lastError = nil

    if let media = await consumePreloadedMedia() {
      applyPreloadedMedia(media)
      isProcessing = false
      return
    }

    let captureService = services.captureService
    let (newMedia, encounteredError) = await collectMedia(for: devices) { device in
      try await captureService.captureScreenshot(for: device)
    }

    applyCaptureResults(newMedia: newMedia, encounteredError: encounteredError)
  }

  func startRecording() async {
    guard canStartRecordingNow else { return }
    let devices = knownDevices
    isProcessing = true
    lastError = nil
    pendingPreferredDeviceID = currentCapture?.deviceID
    updateMediaList([], preserveDeviceID: nil, shouldSort: false, resetTransition: false)

    let deviceIDs = devices.map { $0.id }
    var sessions: [String: RecordingSession] = [:]
    var encounteredError: Error?

    let captureService = services.captureService

    await withTaskGroup(of: (String, Result<RecordingSession, Error>).self) { group in
      for deviceID in deviceIDs {
        group.addTask {
          do {
            let session = try await captureService.startRecording(for: deviceID)
            return (deviceID, .success(session))
          } catch {
            return (deviceID, .failure(error))
          }
        }
      }

      for await (deviceID, result) in group {
        switch result {
        case .success(let session):
          sessions[deviceID] = session
        case .failure(let error):
          encounteredError = error
        }
      }
    }

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
    let sessions = recordingSessions
    let (newMedia, encounteredError) = await collectMedia(for: devices) { device in
      guard let session = sessions[device.id] else { return nil }
      return try await captureService.stopRecording(session: session, device: device)
    }

    applyCaptureResults(newMedia: newMedia, encounteredError: encounteredError)
    recordingSessions.removeAll()
    isRecording = false
  }

  func startLivePreview() async {
    guard canStartLivePreviewNow else { return }
    isProcessing = true
    lastError = nil
    pendingPreferredDeviceID = currentCapture?.deviceID ?? knownDevices.first?.id

    let manager = LivePreviewManager(services: services) { [weak self] media in
      guard let self else { return }
      self.handleLivePreviewMediaUpdate(media)
    }
    livePreviewManager?.stop()
    livePreviewManager = manager
    isLivePreviewActive = true
    await manager.start(with: knownDevices)
  }

  func stopLivePreview() async {
    guard isLivePreviewActive, !isStoppingLivePreview else { return }
    isStoppingLivePreview = true
    let preferredDeviceID = currentCapture?.deviceID
    livePreviewManager?.stop()
    livePreviewManager = nil
    isLivePreviewActive = false
    pendingPreferredDeviceID = preferredDeviceID
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
  }

  func copyCurrentImage() {
    guard let capture = currentCapture,
          case .image(let url, _) = capture.media,
          let image = NSImage(contentsOf: url)
    else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.writeObjects([image])
  }

  func makeTempDragFile(kind: MediaSaveKind) -> URL? {
    guard let media = currentCapture?.media,
          let url = media.url,
          media.saveKind == kind
    else { return nil }

    do {
      let fileStore = services.fileStore
      let fileURL = fileStore.makeDragDestination(
        capturedAt: media.capturedAt,
        kind: kind
      )
      if !FileManager.default.fileExists(atPath: fileURL.path) {
        try FileManager.default.copyItem(at: url, to: fileURL)
      }
      return fileURL
    } catch {
      return nil
    }
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
            return .success(try await action(device))
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

    let collected = await captureService.consumeAllPreloadedScreenshots()
    guard !collected.isEmpty else {
      if shouldLog {
        Perf.step(.appFirstSnapshot, "Preload missing; refreshing preview")
      }
      return nil
    }

    if shouldLog {
      Perf.step(.appFirstSnapshot, "Using preloaded screenshot")
    }
    return collected
  }

  private func applyPreloadedMedia(_ mediaList: [CaptureMedia]) {
    updateMediaList(
      mediaList,
      preserveDeviceID: mediaList.first?.deviceID,
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
      let targetDeviceID = pendingPreferredDeviceID ?? currentCapture?.deviceID
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
    }
    Task.detached(priority: .utility) { [weak self, devices] in
      guard let self else { return }
      await self.services.captureService.preloadScreenshots(for: devices)
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
      if let preloaded = await self.consumePreloadedMedia() {
        await MainActor.run {
          self.applyPreloadedMedia(preloaded)
          self.isProcessing = false
          self.preloadConsumptionTask = nil
        }
      } else {
        await MainActor.run { self.preloadConsumptionTask = nil }
      }
    }
  }

  private func handleLivePreviewMediaUpdate(_ media: [CaptureMedia]) {
    let preferredDeviceID: String?
    if let pendingPreferredDeviceID {
      preferredDeviceID = pendingPreferredDeviceID
    } else if let currentID = selectedMediaID,
              let current = mediaList.first(where: { $0.id == currentID }) {
      preferredDeviceID = current.deviceID
    } else {
      preferredDeviceID = nil
    }

    updateMediaList(
      media,
      preserveDeviceID: preferredDeviceID,
      shouldSort: false,
      resetTransition: false
    )

    if !media.isEmpty {
      isProcessing = false
    }
    pendingPreferredDeviceID = nil
  }

  private func updateMediaList(
    _ newMedia: [CaptureMedia],
    preserveDeviceID: String?,
    shouldSort: Bool,
    resetTransition: Bool
  ) {
    let ordered = shouldSort ? newMedia.sorted { $0.device.displayTitle < $1.device.displayTitle } : newMedia
    mediaList = ordered

    if ordered.isEmpty {
      selectedMediaID = nil
    } else if let preserve = preserveDeviceID,
              let preserved = ordered.first(where: { $0.deviceID == preserve }) {
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
  }

  func livePreviewRenderer(for deviceID: String) -> LivePreviewRenderer? {
    livePreviewManager?.renderer(for: deviceID)
  }
}
