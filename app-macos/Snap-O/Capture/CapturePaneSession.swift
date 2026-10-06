import AppKit
import Foundation
import Observation

enum CapturePaneContent {
  case live(recording: RecordingCapture?)
  case review(CaptureReviewState)
}

/// Owns navigation and this pane's use of previews and capture batches.
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
  private var pendingCommands: [SnapOCommand] = []
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
      return recording.items.compactMap { item in
        switch item.state {
        case .pending, .recording: item.target?.isValid == true ? item.device : nil
        default: nil
        }
      }
    }
    let firstCommand = pendingCommands.first ?? (AppSettings.shared.startupCaptureMode == .screenshot ? .capture : .livepreview)
    guard !needsInitialCapture || deviceOpenRequest != nil || firstCommand != .capture else { return [] }
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
    review?.selectedItem?.device.id ?? selectedPreviewDeviceID
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
    review.map { !$0.batch.isComplete } ?? false
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

  var canCaptureNow: Bool {
    !isClosing && !isRecording && review?.isSaving != true && !(devices.inventory.ready ?? []).isEmpty
  }

  var canStartRecordingNow: Bool {
    !isClosing && !isRecording && review?.isSaving != true && hasDevices
  }

  var canSelectLivePreview: Bool {
    !isClosing && !isRecording && review?.isSaving != true
  }

  var currentCaptureDeviceTitle: String? {
    review?.selectedItem?.device.displayTitle ?? currentPreview?.device.displayTitle
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
    if let review {
      guard review.items.count > 1, let index = review.items.firstIndex(where: { $0.id == review.selectedItemID }) else { return nil }
      return "\(index + 1)/\(review.items.count)"
    }
    guard previews.count > 1, let index = previews.firstIndex(where: { $0.device.id == selectedPreviewDeviceID }) else { return nil }
    return "\(index + 1)/\(previews.count)"
  }

  func start() async {
    guard !hasStarted, !isClosing else { return }
    hasStarted = true
    devices.start()
    if let request = deviceOpenRequest { openDevice(request) }
    observation = Task {
      for await _ in Observations({
        (self.devices.inventory, self.wantedDevices, self.recording?.isComplete, self.review?.selectedItemWasDeleted)
      }) {
        guard !Task.isCancelled, !isClosing else { return }
        update()
      }
    }
  }

  private func update() {
    if let recording, recording.isComplete { showReview(recording) }
    if let review, review.selectedItemWasDeleted { returnToLive(from: review) }
    while let command = pendingCommands.first, canRun(command) {
      pendingCommands.removeFirst()
      perform(command)
    }
    if needsInitialCapture, pendingCommands.isEmpty, deviceOpenRequest == nil {
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

  func enqueue(_ command: SnapOCommand) {
    guard !isClosing else { return }
    pendingCommands.append(command)
    if hasStarted { update() }
  }

  private func canRun(_ command: SnapOCommand) -> Bool {
    command == .capture ? !(devices.inventory.ready ?? []).isEmpty : hasDevices
  }

  private func perform(_ command: SnapOCommand) {
    needsInitialCapture = false
    switch command {
    case .capture: takeScreenshot()
    case .record: startRecording()
    case .livepreview:
      if let review { returnToLive(from: review) }
      claimPreparedPreview()
      reconcilePreviews()
    }
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
    guard canCaptureNow else { return }
    openDevice(nil)
    let targets = devices.inventory.ready ?? []
    let batch = (usePreparation ? services.startup.claimScreenshots(for: targets) : nil) ?? services.screenshots(targets)
    showReview(batch)
    batch.start()
    run { await self.services.startup.discard() }
  }

  func startRecording() {
    guard canStartRecordingNow else { return }
    openDevice(nil)
    let batch = services.recording(devices.inventory.connected ?? [], RecordingOptions(
      recordsBugReport: AppSettings.shared.recordAsBugReport,
      showsTouches: AppSettings.shared.showTouchesDuringCapture
    ))
    if let review { retire(review) }
    content = .live(recording: batch)
    reconcilePreviews()
    run {
      await self.services.startup.discard()
      if batch.options.recordsBugReport {
        for cleanup in Array(self.retiredPreviews.values) {
          await cleanup.value
        }
      }
      if !self.isClosing { batch.start() }
    }
  }

  func stopRecording() {
    guard !isClosing, let recording else { return }
    showReview(recording)
    recording.requestFinish()
  }

  private func showReview(_ batch: any CaptureBatch) {
    lastDisplay = displayInfoForSizing
    let selected = selectedDeviceID
    if let review { retire(review) }
    let review = CaptureReviewState(batch: batch, selectedDeviceID: selected, fileStore: fileStore, history: history)
    content = .review(review)
    review.start()
    review.setVisible(isVisible)
    reconcilePreviews()
  }

  func returnToLive(from expected: CaptureReviewState, selecting deviceID: String? = nil) {
    guard !isClosing, review === expected, !expected.isSaving else { return }
    let preferred = deviceID ?? expected.selectedItem?.device.id ?? selectedPreviewDeviceID
    let available = devices.inventory.connected ?? []
    selectedPreviewDeviceID = preferredDeviceID(
      selected: preferred, originalOrder: expected.batch.items.map(\.device), available: available
    ) ?? preferred
    retire(expected)
    content = .live(recording: nil)
    reconcilePreviews()
  }

  private func retire(_ review: CaptureReviewState) {
    let id = review.batch.id
    guard retiredReviews[id] == nil else { return }
    review.beginClosing()
    let cleanup = Task {
      if !review.batch.isComplete {
        for await complete in Observations({ review.batch.isComplete }) where complete {
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
      selectedPreviewDeviceID = preferredDeviceID(
        selected: selectedPreviewDeviceID, originalOrder: recording?.items.map(\.device) ?? wanted, available: wanted
      ) ?? selectedPreviewDeviceID
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

  private func preferredDeviceID(selected: String?, originalOrder: [Device], available: [Device]) -> String? {
    let availableIDs = Set(available.map(\.id))
    if let selected, availableIDs.contains(selected) { return selected }
    let start = originalOrder.firstIndex { $0.id == selected }.map { $0 + 1 } ?? 0
    for offset in originalOrder.indices {
      let candidate = originalOrder[(start + offset) % originalOrder.count].id
      if availableIDs.contains(candidate) { return candidate }
    }
    return available.first?.id
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
    (review?.items.count ?? previews.count) > 1
  }

  func selectNextMedia() {
    selectNeighbor(1)
  }

  func selectPreviousMedia() {
    selectNeighbor(-1)
  }

  private func selectNeighbor(_ offset: Int) {
    if let review { review.selectNeighbor(offset: offset)
      return
    }
    guard !previews.isEmpty else { return }
    let index = previews.firstIndex { $0.device.id == selectedPreviewDeviceID } ?? 0
    selectDevice(id: previews[(index + offset + previews.count) % previews.count].device.id)
  }

  func setProgressHovering(_ hovering: Bool) {
    hint.setHovered(hovering)
    if hovering { hint.show(available: previews.count > 1, transient: false) }
  }

  func copyCurrentImage() {
    try? review?.copySelectedImage()
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
