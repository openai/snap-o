import AppKit
import Foundation
import Observation

enum CapturePaneContent {
  case live(recording: RecordingCapture?)
  case review(CaptureReviewState)

  @MainActor var allowsReplacement: Bool {
    switch self {
    case .live(let recording): recording == nil
    case .review(let review): review.allowsReplacement
    }
  }
}

/// Owns navigation and this pane's use of previews and capture operations.
@Observable
@MainActor
final class CapturePaneSession {
  let fileStore: FileStore
  private let services: CaptureServices
  private let devices: DeviceManager
  private let history: CaptureHistory
  private(set) var content: CapturePaneContent = .live(recording: nil)
  private(set) var selectedPreviewDeviceID: String?
  private(set) var deviceOpenRequest: DeviceOpenRequest?
  private(set) var deviceOpenStatus: String?
  private(set) var deviceOpenSerial: String?
  private(set) var deviceOpenError: String?
  private var isVisible = true
  @ObservationIgnored private var deviceOpenTask: Task<Void, Never>?
  private(set) var imageCopyID: UUID?
  private(set) var isClosing = false
  let hint = PreviewHint()

  private var displayedPreview: LivePreviewAttachment?
  private var lastDisplay: DisplayInfo?
  private var hasStarted = false
  private var needsInitialCapture = true
  private struct RetiredReview {
    let review: CaptureReviewState
    let cleanup: Task<Void, Never>
  }

  @ObservationIgnored private var retiredReviews: [UUID: RetiredReview] = [:]
  @ObservationIgnored private var retiredPreviews: [UUID: Task<Void, Never>] = [:]
  @ObservationIgnored private var work: [UUID: Task<Void, Never>] = [:]
  @ObservationIgnored private var observation: Task<Void, Never>?
  @ObservationIgnored private var closing: Task<Void, Never>?

  init(services: CaptureServices, devices: DeviceManager, fileStore: FileStore, history: CaptureHistory) {
    self.services = services
    self.devices = devices
    self.fileStore = fileStore
    self.history = history
    selectedPreviewDeviceID = AppSettings.shared.lastViewedDeviceID
  }

  var review: CaptureReviewState? {
    if case .review(let review) = content { return review }
    return nil
  }

  var recording: RecordingCapture? {
    if case .live(let recording) = content { return recording }
    return nil
  }

  private var wantedDevices: [Device] {
    guard case .live = content else { return [] }
    if let recording {
      guard !recording.options.recordsBugReport else { return [] }
      switch recording.state {
      case .pending, .recording: return recording.device.connection?.isValid == true ? [recording.device] : []
      default: return []
      }
    }
    guard !needsInitialCapture || deviceOpenRequest != nil || AppSettings.shared.startupCaptureMode == .livePreview else { return [] }
    return devices.inventory.connected ?? []
  }

  var previews: [LivePreviewDevice] {
    wantedDevices.compactMap { device in
      guard let target = device.connection else { return nil }
      let display = displayedPreview?.target == target ? displayedPreview?.preview?.display : nil
      return LivePreviewDevice(id: target.id, device: device, display: display)
    }
  }

  var currentPreview: LivePreviewDevice? {
    previews.first { $0.device.id == selectedPreviewDeviceID }
  }

  var selectedDeviceID: String? {
    review?.operation.device.id ?? selectedPreviewDeviceID
  }

  var isRecording: Bool {
    recording != nil
  }

  var isFinishingRecording: Bool {
    recording?.phase == .finishing
  }

  var isReviewingCapture: Bool {
    review != nil
  }

  var isLivePreviewActive: Bool {
    review == nil
  }

  var isProcessing: Bool {
    review.map { !$0.operation.isComplete } ?? false
  }

  var hasDevices: Bool {
    !(devices.inventory.connected ?? []).isEmpty
  }

  var isDeviceListInitialized: Bool {
    devices.inventory.connected != nil
  }

  var adbServerState: ADBServerState {
    devices.adbServerState
  }

  var shouldFloatRecordingWindow: Bool {
    recording?.options.recordsBugReport == true
  }

  private var canChangeContent: Bool {
    !isClosing && content.allowsReplacement
  }

  private var captureDevice: Device? {
    let connected = devices.inventory.connected ?? []
    let preferredID = review?.operation.device.id ?? selectedPreviewDeviceID
    let candidate: Device? = if let preferredID {
      connected.first { $0.id == preferredID }
    } else {
      connected.first
    }
    guard let candidate, candidate.connection?.isValid == true else { return nil }
    return devices.inventory.ready?.first {
      $0.id == candidate.id && $0.connection == candidate.connection
    }
  }

  var canCaptureNow: Bool {
    canChangeContent && captureDevice != nil
  }

  var canStartRecordingNow: Bool {
    canChangeContent && captureDevice != nil
  }

  var canSelectLivePreview: Bool {
    canChangeContent
  }

  var currentCaptureDeviceTitle: String? {
    review?.operation.device.displayTitle ?? currentPreview?.device.displayTitle
  }

  var navigationTitle: String {
    currentCaptureDeviceTitle ?? "Snap-O"
  }

  var loadingPreviewDeviceID: String? {
    selectedPreviewDeviceID ?? wantedDevices.first?.id
  }

  var displayInfoForSizing: DisplayInfo? {
    review?.currentCapture?.media.common.display ?? currentPreview?.display ?? lastDisplay
  }

  var captureProgressText: String? {
    guard review == nil else { return nil }
    guard previews.count > 1, let index = previews.firstIndex(where: { $0.device.id == selectedPreviewDeviceID }) else { return nil }
    return "\(index + 1)/\(previews.count)"
  }

  func start() async {
    guard !hasStarted, !isClosing else { return }
    hasStarted = true
    devices.start()
    if let request = deviceOpenRequest {
      openDevice(request)
    } else if !needsInitialCapture {
      claimPreparedPreview()
    }
    observation = Task {
      for await _ in Observations({
        (self.devices.inventory, self.wantedDevices, self.recording?.isComplete)
      }) {
        guard !Task.isCancelled, !isClosing else { return }
        update()
      }
    }
  }

  private func update() {
    if needsInitialCapture, review == nil, let connected = devices.inventory.connected {
      selectedPreviewDeviceID = connected.first { $0.id == selectedPreviewDeviceID }?.id ?? connected.first?.id
    }
    if let recording, recording.isComplete { showReview(recording) }
    if needsInitialCapture, deviceOpenRequest == nil {
      if AppSettings.shared.startupCaptureMode == .screenshot, canCaptureNow {
        needsInitialCapture = false
        takeScreenshot(usePreparation: true)
      } else if AppSettings.shared.startupCaptureMode == .livePreview, hasDevices {
        needsInitialCapture = false
        claimPreparedPreview()
      }
    }
    reconcilePreviews()
  }

  enum UIAction { case screenshot, startRecording, stopRecording, livePreview }
  func launch(_ action: UIAction) {
    guard hasStarted, !isClosing else { return }
    needsInitialCapture = false
    switch action {
    case .screenshot: takeScreenshot()
    case .startRecording: startRecording()
    case .stopRecording: stopRecording()
    case .livePreview: if let review { returnToLive(from: review) }
    }
  }

  func requestLivePreview() {
    guard canChangeContent else { return }
    needsInitialCapture = false
    guard hasStarted else { return }
    if let review { returnToLive(from: review) }
    claimPreparedPreview()
    reconcilePreviews()
  }

  private func claimPreparedPreview() {
    let candidates = devices.inventory.connected ?? []
    guard let device = candidates.first(where: { $0.id == selectedPreviewDeviceID }) ?? candidates.first,
          let prepared = services.startup.claimLivePreview(for: device) else { return }
    if let old = displayedPreview, old !== prepared { retire(old) }
    displayedPreview = prepared
    prepared.setPaneVisible(isVisible)
    selectedPreviewDeviceID = device.id
  }

  func takeScreenshot(usePreparation: Bool = false) {
    guard canCaptureNow, let device = captureDevice else { return }
    openDevice(nil)
    let capture = (usePreparation ? services.startup.claimScreenshots(for: device) : nil) ?? services.screenshots(device)
    showReview(capture)
    capture.start()
    run { await self.services.startup.discard() }
  }

  func startRecording() {
    guard canStartRecordingNow, let device = captureDevice else { return }
    openDevice(nil)
    let capture = services.recording(device, RecordingOptions(
      recordsBugReport: AppSettings.shared.recordAsBugReport,
      showsTouches: AppSettings.shared.showTouchesDuringCapture
    ))
    if let review { retire(review) }
    content = .live(recording: capture)
    reconcilePreviews()
    run {
      await self.services.startup.discard()
      if capture.options.recordsBugReport {
        for cleanup in Array(self.retiredPreviews.values) {
          await cleanup.value
        }
      }
      if !self.isClosing { capture.start() }
    }
  }

  func stopRecording() {
    guard !isClosing, let recording else { return }
    showReview(recording)
    recording.requestFinish()
  }

  private func showReview(_ capture: any CaptureOperation) {
    lastDisplay = displayInfoForSizing
    if let review { retire(review) }
    let review = CaptureReviewState(operation: capture, fileStore: fileStore, history: history.repository)
    content = .review(review)
    review.setVisible(isVisible)
    reconcilePreviews()
  }

  func returnToLive(from expected: CaptureReviewState, selecting deviceID: String? = nil) {
    guard canChangeContent, review === expected else { return }
    let preferred = deviceID ?? expected.operation.device.id
    let available = devices.inventory.connected ?? []
    selectedPreviewDeviceID = available.first { $0.id == preferred }?.id ?? available.first?.id ?? preferred
    retire(expected)
    content = .live(recording: nil)
    reconcilePreviews()
  }

  private func retire(_ review: CaptureReviewState) {
    let id = review.operation.id
    guard retiredReviews[id] == nil else { return }
    review.beginClosing()
    let cleanup = Task {
      if !review.operation.isComplete {
        for await complete in Observations({ review.operation.isComplete }) where complete {
          break
        }
      }
      await review.close()
      retiredReviews[id] = nil
    }
    retiredReviews[id] = RetiredReview(review: review, cleanup: cleanup)
  }

  private func reconcilePreviews() {
    let wanted = wantedDevices
    if review == nil,
       selectedPreviewDeviceID == nil || !wanted.contains(where: { $0.id == selectedPreviewDeviceID }) {
      selectedPreviewDeviceID = wanted.first?.id ?? selectedPreviewDeviceID
    }
    let selected = wanted.first { $0.id == selectedPreviewDeviceID }
    if displayedPreview?.target != selected?.connection {
      if let old = displayedPreview {
        lastDisplay = old.preview?.display ?? lastDisplay
        retire(old)
      }
      displayedPreview = selected.flatMap {
        services.livePreview.attach(to: $0, makeEmulatorControls: services.makeEmulatorControls)
      }
      displayedPreview?.setPaneVisible(isVisible)
    }
    if let display = currentPreview?.display { lastDisplay = display }
  }

  private func retire(_ attachment: LivePreviewAttachment) {
    attachment.setVisible(false)
    retiredPreviews[attachment.id] = Task {
      await attachment.close()
      retiredPreviews[attachment.id] = nil
    }
  }

  func selectDevice(id: String) {
    guard wantedDevices.contains(where: { $0.id == id }) else { return }
    openDevice(nil)
    selectedPreviewDeviceID = id
    AppSettings.shared.lastViewedDeviceID = id
    reconcilePreviews()
    hint.show(available: previews.count > 1, transient: true)
  }

  func setVisible(_ visible: Bool) {
    guard !isClosing else { return }
    isVisible = visible
    displayedPreview?.setPaneVisible(visible)
    review?.setVisible(visible)
  }

  func openDevice(_ request: DeviceOpenRequest?) {
    guard !isClosing else { return }
    deviceOpenTask?.cancel()
    deviceOpenRequest = request
    deviceOpenStatus = request == nil ? nil : "Opening"
    deviceOpenSerial = nil
    deviceOpenError = nil
    guard let request else { return }
    needsInitialCapture = false
    guard hasStarted else { return }
    deviceOpenTask = run {
      defer {
        if !Task.isCancelled, self.deviceOpenRequest == request {
          if self.deviceOpenError == nil { self.deviceOpenRequest = nil }
          self.deviceOpenStatus = nil
        }
      }
      do {
        let serial = try await self.devices.resolve(request) { status in
          guard !Task.isCancelled, self.deviceOpenRequest == request else { return }
          self.deviceOpenStatus = status
        }
        try Task.checkCancellation()
        guard self.deviceOpenRequest == request else { return }
        self.deviceOpenSerial = serial
        self.deviceOpenStatus = "Opening"
        await self.showLivePreview(deviceID: serial)
      } catch is CancellationError {
        return
      } catch {
        guard !Task.isCancelled, self.deviceOpenRequest == request else { return }
        self.deviceOpenError = error.localizedDescription
      }
    }
  }

  func showLivePreview(deviceID: String) async {
    guard !isClosing else { return }
    if isRecording {
      selectDevice(id: deviceID)
      return
    }
    guard canSelectLivePreview else { return }
    needsInitialCapture = false
    if let review { returnToLive(from: review, selecting: deviceID) }
    selectDevice(id: deviceID)
  }

  func livePreviewAttachment(for deviceID: String) -> LivePreviewAttachment? {
    guard let target = wantedDevices.first(where: { $0.id == deviceID })?.connection else { return nil }
    return displayedPreview?.target == target ? displayedPreview : nil
  }

  func livePreviewScreenshot(for deviceID: String) async throws -> Data {
    guard !isClosing else { throw CancellationError() }
    if let attachment = livePreviewAttachment(for: deviceID) {
      return try await attachment.screenshot()
    }
    guard let target = wantedDevices.first(where: { $0.id == deviceID })?.connection else { throw CancellationError() }
    return try await devices.screenshot(for: target)
  }

  func retryADBServer() {
    devices.retryADBServer()
  }

  func hasAlternativeMedia() -> Bool {
    review == nil && previews.count > 1
  }

  func selectNextMedia() {
    selectNeighbor(1)
  }

  func selectPreviousMedia() {
    selectNeighbor(-1)
  }

  private func selectNeighbor(_ offset: Int) {
    guard review == nil else { return }
    guard !previews.isEmpty else { return }
    let index = previews.firstIndex { $0.device.id == selectedPreviewDeviceID } ?? 0
    selectDevice(id: previews[(index + offset + previews.count) % previews.count].device.id)
  }

  func setProgressHovering(_ hovering: Bool) {
    hint.setHovered(hovering)
    if hovering { hint.show(available: previews.count > 1, transient: false) }
  }

  func copyCurrentImage() {
    try? review?.copyImage()
  }

  func imageCopied() {
    imageCopyID = UUID()
  }

  func discardCaptureReview() {
    if let review { returnToLive(from: review) }
  }

  @discardableResult
  private func run(_ body: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
    let id = UUID()
    let task = Task {
      guard !Task.isCancelled else { work[id] = nil
        return
      }
      await body()
      work[id] = nil
    }
    work[id] = task
    return task
  }

  func close() async {
    if let closing { await closing.value
      return
    }
    isClosing = true
    observation?.cancel()
    hint.cancel()
    for task in work.values {
      task.cancel()
    }
    let review = review
    let recording = recording
    let retired = Array(retiredReviews.values)
    if let displayedPreview { retire(displayedPreview) }
    displayedPreview = nil
    let pendingPreviews = Array(retiredPreviews.values)
    let pendingWork = Array(work.values)
    let closing = Task {
      await withTaskGroup(of: Void.self) { group in
        if let review { group.addTask { await review.close() } }
        if let recording { group.addTask { await recording.close() } }
        for old in retired {
          group.addTask { await old.review.close()
            await old.cleanup.value
          }
        }
        for pending in pendingPreviews {
          group.addTask { await pending.value }
        }
      }
      await observation?.value
      for pending in pendingWork {
        await pending.value
      }
    }
    self.closing = closing
    await closing.value
  }
}
