import Clocks
import DependenciesTestSupport
import Foundation
import Testing

@MainActor
@Suite(.serialized, .dependency(\.continuousClock, TestClock()))
struct CapturePaneTests {
  @Test
  func pickerDoesNotStartUnselectedPreviews() async throws {
    let fixture = Fixture(deviceIDs: ["A", "B", "C"])
    let pane = fixture.pane()
    await fixture.start(pane)
    #expect(pane.previews.map(\.device.id) == ["A", "B", "C"])
    #expect(fixture.previews.attachments.map(\.target.serial) == ["A"])
    let first = try #require(pane.livePreviewAttachment(for: "A"))
    pane.startRecording()
    let batch = try #require(pane.recording)
    #expect(batch.items.map(\.device.id) == ["A", "B", "C"])
    #expect(fixture.previews.attachments.count == 1)
    pane.selectDevice(id: "B")
    try #require(pane.livePreviewAttachment(for: "A") == nil)
    #expect(pane.livePreviewAttachment(for: "B") != nil)
    #expect(pane.livePreviewAttachment(for: "C") == nil)
    try await waitForState { first.isClosed }
    #expect(batch.closeCount == 0)
    await pane.close()
    await fixture.close()
  }

  @Test(arguments: ["B", "C"])
  func deviceOpenDuringRecordingUsesOnlyRecordingTargets(requestedDevice: String) async throws {
    let fixture = Fixture(deviceIDs: ["A", "B", "C"])
    fixture.devices.inventory.ready = try Array(#require(fixture.devices.inventory.connected).prefix(2))
    let pane = fixture.pane()
    await fixture.start(pane)
    pane.startRecording()
    let batch = try #require(pane.recording)

    pane.openDevice(.serial(requestedDevice))
    try await waitForState { pane.deviceOpenRequest == nil }

    #expect(pane.selectedPreviewDeviceID == (requestedDevice == "B" ? "B" : "A"))
    #expect(pane.recording === batch)
    #expect(batch.closeCount == 0)
    await pane.close()
    await fixture.close()
  }

  @Test
  func switchingPreviewReleasesOnlyThisWindowsAttachment() async throws {
    let fixture = Fixture()
    let first = fixture.pane()
    let second = fixture.pane()
    await fixture.start(first, second)
    let old = try #require(first.livePreviewAttachment(for: "A"))
    let other = try #require(second.livePreviewAttachment(for: "A"))
    first.selectDevice(id: "B")
    try #require(first.livePreviewAttachment(for: "A") == nil)
    try await waitForState { old.isClosed }
    #expect(!other.isClosed)
    #expect(second.livePreviewAttachment(for: "B") == nil)
    await first.close()
    #expect(!other.isClosed)
    await second.close()
    await fixture.close()
  }

  @Test
  func unselectedThumbnailDoesNotStartPreview() async throws {
    let fixture = Fixture()
    let pane = fixture.pane()
    await fixture.start(pane)
    _ = try await pane.livePreviewScreenshot(for: "B")
    #expect(fixture.devices.screenshotTargets.map(\.serial) == ["B"])
    #expect(fixture.previews.attachments.map(\.target.serial) == ["A"])
    await pane.close()
    await fixture.close()
  }

  @Test
  func openingDeviceFromReviewDoesNotStartThePreviousPreview() async {
    let fixture = Fixture()
    let pane = fixture.pane()
    await fixture.start(pane)
    pane.takeScreenshot()
    let previousCount = fixture.previews.attachments.count
    await pane.showLivePreview(deviceID: "B")
    #expect(fixture.previews.attachments.dropFirst(previousCount).map(\.target.serial) == ["B"])
    await pane.close()
    await fixture.close()
  }

  @Test
  func recordingFailureChangesOnlyItsWindowsPicker() async throws {
    let fixture = Fixture()
    let left = fixture.pane()
    let right = fixture.pane()
    await fixture.start(left, right)
    left.selectDevice(id: "B")
    right.selectDevice(id: "A")
    left.startRecording()
    let batch = try #require(left.recording)
    #expect(left.previews.map(\.device.id) == ["A", "B"], "Pending recording targets remain visible")
    batch.items[1].update(.failed("Could not record"))
    try await waitForState { left.currentPreview?.device.id == "A" }
    #expect(left.previews.map(\.device.id) == ["A"])
    #expect(right.previews.map(\.device.id) == ["A", "B"])
    #expect(right.selectedPreviewDeviceID == "A")
    await left.close()
    #expect(right.livePreviewAttachment(for: "A")?.isClosed == false)
    await right.close()
    await fixture.close()
  }

  @Test(arguments: ["B", "C"])
  func failedRecordingSelectsNextOriginalTarget(selected: String) async throws {
    let fixture = Fixture(deviceIDs: ["A", "B", "C"])
    let pane = fixture.pane()
    await fixture.start(pane)
    pane.startRecording()
    pane.selectDevice(id: selected)
    let batch = try #require(pane.recording)
    let item = try #require(batch.items.first { $0.device.id == selected })
    let oldAttachment = try #require(pane.livePreviewAttachment(for: selected))
    item.update(.failed("Recording failed"))
    try await waitForState { oldAttachment.isClosed }
    #expect(pane.selectedPreviewDeviceID == (selected == "B" ? "C" : "A"))
    await pane.close()
    await fixture.close()
  }

  @Test(arguments: ["B", "C"])
  func returningFromReviewPrefersOriginalTargetOrder(selected: String) async throws {
    let fixture = Fixture(deviceIDs: ["A", "B", "C", "D"])
    let discovered = fixture.devices.inventory.connected ?? []
    fixture.devices.inventory.connected = Array(discovered.prefix(3))
    fixture.devices.inventory.ready = Array(discovered.prefix(3))
    let pane = fixture.pane()
    await fixture.start(pane)
    pane.selectDevice(id: selected)
    pane.takeScreenshot()
    let review = try #require(pane.review)
    // D appeared after capture. Current discovery order must not replace batch order.
    fixture.devices.inventory.connected = discovered.reversed().filter { $0.id != selected }
    pane.returnToLive(from: review)
    #expect(pane.selectedPreviewDeviceID == (selected == "B" ? "C" : "A"))
    await pane.close()
    await fixture.close()
  }

  @Test
  func returningFromReviewUsesNewDeviceWhenAllBatchTargetsAreGone() async throws {
    let fixture = Fixture(deviceIDs: ["A", "B", "C", "D"])
    let discovered = fixture.devices.inventory.connected ?? []
    fixture.devices.inventory.connected = Array(discovered.prefix(3))
    fixture.devices.inventory.ready = Array(discovered.prefix(3))
    let pane = fixture.pane()
    await fixture.start(pane)
    pane.selectDevice(id: "B")
    pane.takeScreenshot()
    let review = try #require(pane.review)
    fixture.devices.inventory.connected = discovered.filter { $0.id == "D" }
    pane.returnToLive(from: review)
    #expect(pane.selectedPreviewDeviceID == "D")
    await pane.close()
    await fixture.close()
  }

  @Test
  func stopSelectsTheViewedDeviceBeforeAnyResultArrives() async throws {
    let fixture = Fixture()
    let pane = fixture.pane()
    await fixture.start(pane)
    pane.startRecording()
    pane.selectDevice(id: "B")
    let batch = try #require(pane.recording)
    pane.stopRecording()
    let review = try #require(pane.review)
    #expect(review.batch === batch)
    #expect(review.selectedItem?.device.id == "B")
    #expect(review.currentCapture == nil)
    batch.items[0].update(.failed("Unavailable"))
    #expect(review.selectedItem?.device.id == "B")
    await pane.close()
    await fixture.close()
  }

  @Test
  func returningToLiveKeepsFinalizationOwnedUntilItCompletes() async throws {
    let fixture = Fixture()
    let pane = fixture.pane()
    await fixture.start(pane)
    pane.startRecording()
    let batch = try #require(pane.recording)
    pane.stopRecording()
    let review = try #require(pane.review)
    review.select(batch.items[1].id)
    pane.returnToLive(from: review)
    #expect(pane.isLivePreviewActive)
    #expect(pane.selectedPreviewDeviceID == "B")
    #expect(batch.closeCount == 0 && !batch.isComplete)
    batch.isComplete = true
    try await waitForState { batch.closeCount == 1 }
    #expect(pane.isLivePreviewActive)
    await pane.close()
    await fixture.close()
  }

  @Test
  func disconnectedSelectionWaitsWhenNoDevicesRemain() async throws {
    let fixture = Fixture(deviceIDs: ["A"])
    let pane = fixture.pane()
    await fixture.start(pane)
    let connected = fixture.devices.inventory.connected ?? []
    let oldAttachment = try #require(pane.livePreviewAttachment(for: "A"))
    fixture.devices.inventory.connected = []
    try await waitForState { oldAttachment.isClosed }
    #expect(pane.currentPreview == nil)
    #expect(pane.loadingPreviewDeviceID == "A")
    fixture.devices.inventory.connected = connected
    try await waitForState { pane.livePreviewAttachment(for: "A") != nil }
    #expect(pane.currentPreview?.device.id == "A")
    await pane.close()
    await fixture.close()
  }

  @Test(arguments: [false, true])
  func disconnectedSelectionShowsAnAvailableDevice(withEmptyInterval: Bool) async throws {
    let fixture = Fixture()
    let pane = fixture.pane()
    await fixture.start(pane)
    pane.selectDevice(id: "B")
    let remaining = (fixture.devices.inventory.connected ?? []).filter { $0.id == "A" }
    let oldAttachment = try #require(pane.livePreviewAttachment(for: "B"))
    if withEmptyInterval {
      fixture.devices.inventory.connected = []
      try await waitForState { oldAttachment.isClosed }
    }
    fixture.devices.inventory.connected = remaining
    try await waitForState { pane.livePreviewAttachment(for: "A") != nil && oldAttachment.isClosed }
    #expect(pane.currentPreview?.device.id == "A")
    await pane.close()
    await fixture.close()
  }

  @Test
  func aNewDeviceDoesNotReplaceAConnectedSelection() async throws {
    let fixture = Fixture()
    let connected = fixture.devices.inventory.connected ?? []
    fixture.devices.inventory.connected = connected.filter { $0.id == "A" }
    let pane = fixture.pane()
    await fixture.start(pane)
    fixture.devices.inventory.connected = connected
    try await waitForState { pane.previews.count == 2 }
    #expect(pane.currentPreview?.device.id == "A")
    #expect(pane.livePreviewAttachment(for: "B") == nil)
    await pane.close()
    await fixture.close()
  }

  @Test
  func returningFromReviewFallsBackWhenItsDeviceIsUnavailable() async throws {
    let fixture = Fixture()
    let pane = fixture.pane()
    await fixture.start(pane)
    pane.selectDevice(id: "B")
    pane.takeScreenshot()
    let review = try #require(pane.review)
    #expect(review.selectedItem?.device.id == "B")
    fixture.devices.inventory.connected?.removeAll { $0.id == "B" }
    pane.returnToLive(from: review)
    #expect(pane.currentPreview?.device.id == "A")
    await pane.close()
    await fixture.close()
  }

  @Test(arguments: [false, true])
  func deletingSelectedHistoryItemReturnsToLive(disconnected: Bool) async throws {
    let fixture = Fixture()
    let pane = fixture.pane()
    await fixture.start(pane)
    pane.takeScreenshot()
    let batch = try #require(fixture.screenshots.value.first)
    let item = try #require(batch.items.first)
    let entryID = try #require(await fixture.history.repository.begin(kind: .image, devices: [item.device]))
    let url = fixture.store.makePreviewDestination(deviceID: item.device.id, capturedAt: Date(), kind: .image)
    try Data([1]).write(to: url)
    let media = CaptureMedia(device: item.device, media: .image(
      url: url, capturedAt: Date(), display: DisplayInfo(size: CGSize(width: 1, height: 1), densityScale: 1)
    ))
    await item.update(.ready(fixture.history.repository.record(media, in: entryID)))
    batch.isComplete = true
    await fixture.history.repository.finish(entryID)
    fixture.history.start()
    try await waitForState { fixture.history.isLoaded }
    if disconnected {
      fixture.devices.inventory = DeviceInventory(connected: [], ready: [])
    }
    await fixture.history.repository.delete([entryID])
    try await waitForState { pane.isLivePreviewActive }
    #expect(disconnected ? pane.currentPreview == nil : pane.currentPreview?.device.id == "A")
    await pane.close()
    await fixture.close()
  }

  @Test
  func pendingReviewKeepsTheLiveDisplaySize() async {
    let fixture = Fixture()
    let pane = fixture.pane()
    await fixture.start(pane)
    let display = DisplayInfo(size: CGSize(width: 1080, height: 2400), densityScale: 3)
    pane.livePreviewAttachment(for: "A")?.preview?.display = display
    pane.takeScreenshot()
    #expect(pane.review?.currentCapture == nil)
    #expect(pane.displayInfoForSizing == display)
    await pane.close()
    await fixture.close()
  }

  @Test
  func screenshotStartupDoesNotStartUnusedPreviews() async throws {
    let fixture = Fixture()
    AppSettings.shared.startupCaptureMode = .screenshot
    fixture.devices.inventory.ready = nil
    let pane = fixture.pane()
    await pane.start()
    #expect(pane.previews.isEmpty)
    fixture.devices.inventory.ready = fixture.devices.inventory.connected
    try await waitForState { pane.review != nil }
    #expect(fixture.previews.attachments.isEmpty)
    await pane.close()
    await fixture.close()
  }

  @Test
  func hidingThePaneKeepsItsRecordingAndSelection() async throws {
    let fixture = Fixture()
    let pane = fixture.pane()
    await fixture.start(pane)
    pane.selectDevice(id: "B")
    pane.startRecording()
    let batch = try #require(pane.recording)
    let attachment = try #require(pane.livePreviewAttachment(for: "B"))
    pane.setVisible(false)
    #expect(!attachment.isPaneVisible && !attachment.isClosed)
    #expect(pane.recording === batch && batch.closeCount == 0)
    #expect(pane.selectedPreviewDeviceID == "B")
    pane.setVisible(true)
    #expect(attachment.isPaneVisible && pane.recording === batch)
    await pane.close()
    await fixture.close()
  }

  @Test
  func lateDeviceOpenCannotReplaceManualSelection() async {
    let fixture = Fixture()
    let gate = TestSuspension()
    fixture.devices.resolveRequest = { _, progress in
      try? await gate.wait()
      progress("Connecting")
      return "A"
    }
    let pane = fixture.pane()
    await fixture.start(pane)
    pane.openDevice(.serial("A"))
    await gate.waitUntilStarted()
    pane.selectDevice(id: "B")
    gate.resume()
    await pane.close()
    #expect(pane.selectedPreviewDeviceID == "B")
    #expect(pane.deviceOpenRequest == nil && pane.deviceOpenError == nil)
    #expect(pane.deviceOpenStatus == nil, "A cancelled request cannot restore its progress message")
    await fixture.close()
  }

  @Test
  func failedDeviceOpenKeepsItsTargetForRetry() async throws {
    let fixture = Fixture()
    let request = DeviceOpenRequest.avd("Test emulator", start: true)
    var requests: [DeviceOpenRequest] = []
    fixture.devices.resolveRequest = { request, _ in
      requests.append(request)
      if requests.count == 1 { throw CocoaError(.fileReadUnknown) }
      return "A"
    }
    let pane = fixture.pane()
    await fixture.start(pane)
    pane.selectDevice(id: "B")
    pane.openDevice(request)
    try await waitForState { pane.deviceOpenError != nil }
    #expect(pane.deviceOpenRequest == request)
    #expect(pane.deviceOpenStatus == nil, "Failure must not retain a loading message")
    #expect(pane.selectedPreviewDeviceID == "B")
    if let retry = pane.deviceOpenRequest {
      pane.openDevice(retry)
      #expect(pane.deviceOpenError == nil)
      try await waitForState { pane.selectedPreviewDeviceID == "A" }
      #expect(requests == [request, request])
      #expect(pane.deviceOpenRequest == nil)
    }
    await pane.close()
    await fixture.close()
  }

  @Test
  func cancellingFailedDeviceOpenKeepsTheCurrentReview() async throws {
    let fixture = Fixture()
    fixture.devices.resolveRequest = { _, _ in throw CocoaError(.fileReadUnknown) }
    let pane = fixture.pane()
    await fixture.start(pane)
    pane.takeScreenshot()
    let review = try #require(pane.review)
    pane.openDevice(.avd("Test emulator", start: true))
    try await waitForState { pane.deviceOpenError != nil }
    pane.openDevice(nil)
    #expect(pane.deviceOpenRequest == nil && pane.deviceOpenError == nil && pane.deviceOpenStatus == nil)
    #expect(pane.review === review)
    await pane.close()
    await fixture.close()
  }

  @Test(arguments: [false, true])
  func newCaptureCancelsPendingDeviceOpen(recording: Bool) async {
    let fixture = Fixture()
    let gate = TestGate()
    fixture.devices.resolveRequest = { _, progress in
      await gate.wait()
      progress("Late progress")
      return "B"
    }
    let pane = fixture.pane()
    await fixture.start(pane)
    pane.openDevice(.avd("Test emulator", start: true))
    await gate.waitUntilEntered()
    if recording { pane.startRecording() } else { pane.takeScreenshot() }
    let review = pane.review
    let batch = pane.recording
    #expect(pane.deviceOpenRequest == nil && pane.deviceOpenStatus == nil)
    await gate.open()
    await pane.close()
    #expect(pane.review === review && pane.recording === batch)
    #expect(pane.deviceOpenSerial == nil && pane.deviceOpenError == nil)
    await fixture.close()
  }

  @Test(arguments: [false, true])
  func closeJoinsSupersededDeviceOpen(fails: Bool) async throws {
    let fixture = Fixture()
    let gate = TestGate()
    fixture.devices.resolveRequest = { request, progress in
      if request == .serial("A") {
        await gate.wait()
        progress("Old request")
        if fails { throw CocoaError(.fileReadUnknown) }
        return "A"
      }
      return "B"
    }
    let pane = fixture.pane()
    await fixture.start(pane)
    pane.openDevice(.serial("A"))
    await gate.waitUntilEntered()
    pane.openDevice(.serial("B"))
    try await waitForState { pane.selectedPreviewDeviceID == "B" }
    let finished = TestValue(false)
    let closing = Task { await pane.close()
      finished.value = true
    }
    try await waitForState { pane.isClosing }
    #expect(!finished.value, "Superseded work stays owned until it returns")
    await gate.open()
    await closing.value
    #expect(pane.selectedPreviewDeviceID == "B")
    #expect(pane.deviceOpenStatus == nil && pane.deviceOpenError == nil)
    await fixture.close()
  }

  @Test
  func savingReviewRejectsReplacementUntilSaveCompletes() async throws {
    let fixture = Fixture()
    let pane = fixture.pane()
    await fixture.start(pane)
    pane.takeScreenshot()
    let review = try #require(pane.review)
    let save = Task { try await review.saveToHistory(name: "Pending batch") }
    try await waitForState { review.isSaving }
    pane.takeScreenshot()
    pane.startRecording()
    pane.returnToLive(from: review)
    #expect(pane.review === review)
    #expect(fixture.screenshots.value.count == 1 && fixture.recordings.value.isEmpty)
    let batch = try #require(fixture.screenshots.value.first)
    for item in batch.items {
      item.update(.failed("Unavailable"))
    }
    batch.isComplete = true
    await #expect(throws: (any Error).self) { try await save.value }
    #expect(pane.review === review, "A failed save keeps review available")
    pane.takeScreenshot()
    #expect(pane.review !== review && fixture.screenshots.value.count == 2)
    await pane.close()
    await fixture.close()
  }

  @Test
  func oldReviewCallbackCannotDismissANewCapture() async throws {
    let fixture = Fixture()
    let pane = fixture.pane()
    await fixture.start(pane)
    pane.takeScreenshot()
    let old = try #require(pane.review)
    pane.takeScreenshot()
    let current = try #require(pane.review)
    pane.returnToLive(from: old)
    #expect(pane.review === current)
    await pane.close()
    await fixture.close()
  }

  @Test
  func closingWaitsForBackgroundRecordingCleanup() async throws {
    let fixture = Fixture()
    let pane = fixture.pane()
    await fixture.start(pane)
    pane.startRecording()
    let batch = try #require(pane.recording)
    pane.stopRecording()
    try pane.returnToLive(from: #require(pane.review))
    let gate = TestSuspension()
    batch.closeGate = gate
    let finished = TestValue(false)
    let closing = Task { await pane.close()
      finished.value = true
    }
    await gate.waitUntilStarted()
    #expect(!finished.value)
    gate.resume()
    await closing.value
    #expect(batch.closeCount == 1 && finished.value)
    await fixture.close()
  }

  @Test
  func windowDefersPaneStartupUntilItIsActivated() async throws {
    let fixture = Fixture()
    let pane = fixture.pane()
    let session = fixture.window(pane, showsCapture: false, showsTool: true)
    session.perform(.livepreview)
    #expect(fixture.previews.attachments.isEmpty && session.tools.starts == 0)
    session.startIfNeeded()
    try await waitForState { pane.livePreviewAttachment(for: "A") != nil }
    #expect(session.workspace.layout == .both && session.tools.starts == 1)
    session.startIfNeeded()
    #expect(session.tools.starts == 1)
    await session.close().value
    await fixture.close()
  }

  @Test
  func windowHideRetainsBothPanes() async throws {
    let fixture = Fixture()
    let pane = fixture.pane()
    let session = fixture.window(pane, showsCapture: true, showsTool: true)
    session.startIfNeeded()
    try await waitForState { pane.livePreviewAttachment(for: "A") != nil }
    let attachment = try #require(pane.livePreviewAttachment(for: "A"))
    session.workspace.toggleCapture()
    session.updatePaneVisibility()
    #expect(!attachment.isPaneVisible && !attachment.isClosed)
    session.workspace.revealCapture()
    session.workspace.toggleTool()
    session.updatePaneVisibility()
    #expect(attachment.isPaneVisible)
    #expect(!session.tools.isVisible && !session.tools.isClosed)
    await session.close().value
    await fixture.close()
  }

  @Test
  func windowClosesToolsWhileRecordingCleanupWaits() async throws {
    let fixture = Fixture()
    let pane = fixture.pane()
    let session = fixture.window(pane, showsCapture: true, showsTool: true)
    session.startIfNeeded()
    try await waitForState { pane.livePreviewAttachment(for: "A") != nil }
    pane.startRecording()
    let batch = try #require(pane.recording)
    let gate = TestSuspension()
    batch.closeGate = gate
    let closing = session.close()
    await gate.waitUntilStarted()
    try await waitForState { session.tools.isClosed }
    #expect(!batch.isComplete)
    session.perform(.capture)
    #expect(pane.review == nil, "Closing windows reject new commands")
    gate.resume()
    await closing.value
    #expect(batch.isComplete)
    await fixture.close()
  }

  @Test
  func deviceOpenBeforeActivationSkipsDefaultScreenshot() async throws {
    let fixture = Fixture()
    AppSettings.shared.startupCaptureMode = .screenshot
    let pane = fixture.pane()
    let session = fixture.window(pane, showsCapture: false, showsTool: true)
    session.openDevice(.serial("B"))
    session.startIfNeeded()
    try await waitForState { pane.selectedPreviewDeviceID == "B" }
    #expect(pane.review == nil && session.workspace.showsCapture)
    await session.close().value
    await fixture.close()
  }

  @MainActor
  final class Fixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let devices = DeviceManager()
    let previews = LivePreviewService()
    let screenshots = TestValue<[ScreenshotCapture]>([])
    let recordings = TestValue<[RecordingCapture]>([])
    let store: FileStore
    let history: CaptureHistory
    init(deviceIDs: [String] = ["A", "B"]) {
      AppSettings.shared.lastViewedDeviceID = nil
      AppSettings.shared.startupCaptureMode = .livePreview
      AppSettings.shared.recordAsBugReport = false
      store = FileStore(baseDir: root.appendingPathComponent("drafts"))
      history = CaptureHistory(repository: CaptureHistoryRepository(root: root.appendingPathComponent("history")))
      let connected = deviceIDs.map { serial in
        Device(
          id: serial, model: serial, androidVersion: "16", vendorModel: nil, manufacturer: nil, avdName: nil,
          connection: DeviceTarget(serial: serial, transportID: serial)
        )
      }
      devices.inventory = DeviceInventory(connected: connected, ready: connected)
    }

    var services: CaptureServices {
      CaptureServices(
        livePreview: previews,
        screenshots: { devices in
          let batch = ScreenshotCapture(devices)
          self.screenshots.value.append(batch)
          return batch
        },
        recording: { devices, options in
          let batch = RecordingCapture(devices, options: options)
          self.recordings.value.append(batch)
          return batch
        }
      )
    }

    func pane() -> CapturePaneSession {
      CapturePaneSession(services: services, devices: devices, fileStore: store, history: history)
    }

    func workspaces() -> CaptureWorkspaces {
      CaptureWorkspaces(
        captureServices: services, deviceManager: devices, fileStore: store,
        adbService: ADBService(), history: history
      )
    }

    func window(_ pane: CapturePaneSession, showsCapture: Bool, showsTool: Bool) -> CaptureWindowSession {
      guard let defaults = UserDefaults(suiteName: root.lastPathComponent) else { preconditionFailure("Missing test defaults") }
      let workspace = WorkspaceLayoutController(
        snapshot: WorkspaceLayoutSnapshot(showsCapture: showsCapture, showsTool: showsTool, capturePaneWidth: 360),
        defaults: defaults
      )
      return CaptureWindowSession(capture: pane, tools: ToolSession(), workspace: workspace)
    }

    func start(_ panes: CapturePaneSession...) async {
      for pane in panes {
        pane.enqueue(.livepreview)
        await pane.start()
        try? await waitForState {
          guard let selected = pane.selectedPreviewDeviceID else { return false }
          return pane.livePreviewAttachment(for: selected) != nil
        }
      }
    }

    func close() async {
      await history.shutdown()
      UserDefaults().removePersistentDomain(forName: root.lastPathComponent)
      try? FileManager.default.removeItem(at: root)
    }
  }
}
