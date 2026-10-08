import Foundation
import Testing

extension CapturePaneTests {
  @Test(arguments: [false, true])
  func captureUsesOnlyTheSelectedDevice(recording: Bool) async {
    let fixture = Fixture()
    let pane = fixture.pane()
    await fixture.start(pane)
    pane.selectDevice(id: "B")
    if recording { pane.startRecording() } else { pane.takeScreenshot() }
    let operation: (any CaptureOperation)? = recording ? pane.recording : pane.review?.operation
    #expect(operation?.device.id == "B")
    #expect(fixture.recordings.value.count + fixture.screenshots.value.count == 1)
    #expect(!pane.hasAlternativeMedia())
    await pane.close()
    await fixture.close()
  }

  @Test(arguments: [false, true])
  func unreadySelectionDoesNotCaptureAnotherDevice(recording: Bool) async {
    let fixture = Fixture()
    let pane = fixture.pane()
    await fixture.start(pane)
    pane.selectDevice(id: "B")
    fixture.devices.inventory.ready = fixture.devices.inventory.connected?.filter { $0.id == "A" }
    #expect(!pane.canCaptureNow && !pane.canStartRecordingNow)
    if recording { pane.startRecording() } else { pane.takeScreenshot() }
    #expect(fixture.recordings.value.isEmpty && fixture.screenshots.value.isEmpty)
    await pane.close()
    await fixture.close()
  }

  @Test
  func staleReadyConnectionCannotCaptureTheReplacement() async throws {
    let fixture = Fixture()
    let pane = fixture.pane()
    await fixture.start(pane)
    pane.selectDevice(id: "B")
    let old = try #require(fixture.devices.inventory.connected?.last)
    let replacement = Device(
      id: old.id, model: old.model, androidVersion: old.androidVersion,
      vendorModel: nil, manufacturer: nil, avdName: nil,
      connection: DeviceTarget(serial: "B", transportID: "replacement")
    )
    fixture.devices.inventory.connected = [replacement]
    #expect(!pane.canCaptureNow && !pane.canStartRecordingNow)
    pane.takeScreenshot()
    #expect(fixture.screenshots.value.isEmpty)
    await pane.close()
    await fixture.close()
  }

  @Test(arguments: ["B", "missing"])
  func startupScreenshotResolvesOnePreferredDevice(preferred: String) async throws {
    let fixture = Fixture()
    AppSettings.shared.startupCaptureMode = .screenshot
    AppSettings.shared.lastViewedDeviceID = preferred
    let pane = fixture.pane()
    await pane.start()
    try await waitForState { pane.review != nil }
    #expect(pane.review?.operation.device.id == (preferred == "B" ? "B" : "A"))
    #expect(fixture.screenshots.value.count == 1)
    await pane.close()
    await fixture.close()
  }

  @Test(arguments: [false, true])
  func recordingRequiresReadyDevice(readinessKnown: Bool) async {
    let fixture = Fixture()
    fixture.devices.inventory.ready = readinessKnown ? [] : nil
    let pane = fixture.pane()
    await fixture.start(pane)
    #expect(!pane.canStartRecordingNow)
    pane.launch(.startRecording)
    #expect(fixture.recordings.value.isEmpty)
    fixture.devices.inventory.ready = fixture.devices.inventory.connected
    #expect(pane.canStartRecordingNow)
    #expect(fixture.recordings.value.isEmpty, "Becoming ready must not start a rejected recording")
    pane.launch(.startRecording)
    #expect(fixture.recordings.value.count == 1)
    await pane.close()
    await fixture.close()
  }

  @Test
  func recordingIncludesOnlyReadyDevice() async {
    let fixture = Fixture()
    fixture.devices.inventory.ready = fixture.devices.inventory.connected?.filter { $0.id == "A" }
    let pane = fixture.pane()
    await fixture.start(pane)
    pane.launch(.startRecording)
    #expect(pane.recording?.device.id == "A")
    await pane.close()
    await fixture.close()
  }

  @Test(arguments: [StartupCaptureMode.screenshot, .livePreview], [false, true])
  func livePreviewRequestOverridesStartupMode(mode: StartupCaptureMode, wantsPreview: Bool) async throws {
    let fixture = Fixture()
    AppSettings.shared.startupCaptureMode = mode
    let available = fixture.devices.inventory
    fixture.devices.inventory = DeviceInventory()
    let pane = fixture.pane()
    if wantsPreview { pane.requestLivePreview() }
    await pane.start()
    await pane.start()
    #expect(fixture.screenshots.value.isEmpty && fixture.recordings.value.isEmpty)
    fixture.devices.inventory = available
    if !wantsPreview, mode == .screenshot {
      try await waitForState { pane.review != nil }
      #expect(fixture.screenshots.value.count == 1)
      #expect(fixture.previews.attachments.isEmpty)
    } else {
      try await waitForState { pane.currentPreview != nil }
      #expect(fixture.screenshots.value.isEmpty)
    }
    #expect(fixture.recordings.value.isEmpty)
    await pane.close()
    await fixture.close()
  }

  @Test
  func previewCommandUsesConnectedDeviceBeforeAndroidIsReady() async throws {
    let fixture = Fixture()
    fixture.devices.inventory.ready = nil
    AppSettings.shared.startupCaptureMode = .screenshot
    let pane = fixture.pane()
    pane.requestLivePreview()
    await pane.start()
    try await waitForState { pane.currentPreview != nil }
    #expect(fixture.screenshots.value.isEmpty)
    await pane.close()
    await fixture.close()
  }

  @Test
  func toolbarActionsBeforeActivationDoNotSuppressStartup() async throws {
    let fixture = Fixture()
    AppSettings.shared.startupCaptureMode = .screenshot
    let pane = fixture.pane()
    pane.launch(.startRecording)
    pane.launch(.screenshot)
    pane.launch(.stopRecording)
    #expect(fixture.screenshots.value.isEmpty && fixture.recordings.value.isEmpty)
    await pane.start()
    try await waitForState { pane.review != nil }
    #expect(fixture.screenshots.value.count == 1 && fixture.recordings.value.isEmpty)
    await pane.close()
    await fixture.close()
  }

  @Test
  func closingRejectsLivePreviewRequests() async {
    let fixture = Fixture()
    let available = fixture.devices.inventory
    fixture.devices.inventory = DeviceInventory()
    let pane = fixture.pane()
    pane.requestLivePreview()
    await pane.start()
    await pane.close()
    fixture.devices.inventory = available
    pane.requestLivePreview()
    await pane.start()
    #expect(fixture.screenshots.value.isEmpty && fixture.recordings.value.isEmpty)
    #expect(fixture.previews.attachments.isEmpty)
    await fixture.close()
  }

  @Test
  func recordingReusesPreviewsWithoutWaitingForDisplayInfo() async throws {
    let fixture = Fixture()
    let pane = fixture.pane()
    await fixture.start(pane)
    let attachment = try #require(pane.livePreviewAttachment(for: "A"))
    #expect(attachment.preview?.display == nil)
    pane.startRecording()
    try await waitForState { pane.recording?.phase == .recording }
    let batch = try #require(pane.recording)
    #expect(pane.livePreviewAttachment(for: "A") === attachment)
    #expect(!attachment.isClosed)
    pane.takeScreenshot()
    pane.requestLivePreview()
    #expect(pane.recording === batch && fixture.screenshots.value.isEmpty)
    pane.stopRecording()
    #expect(pane.review?.operation === batch)
    #expect(batch.phase == .finishing)
    await pane.close()
    await fixture.close()
  }

  @Test(arguments: [CapturePaneSession.UIAction.screenshot, .startRecording, .livePreview])
  func actionsDuringRecordingDoNotRunLater(action: CapturePaneSession.UIAction) async throws {
    let fixture = Fixture()
    let pane = fixture.pane()
    await fixture.start(pane)
    pane.startRecording()
    let batch = try #require(pane.recording)
    let available = fixture.devices.inventory
    fixture.devices.inventory = DeviceInventory()
    pane.launch(action)
    #expect(pane.recording === batch)

    pane.stopRecording()
    fixture.devices.inventory = available
    let attachments = fixture.previews.attachments.count
    // A rejected action must not start work after the recording ends.
    pane.takeScreenshot()
    #expect(fixture.screenshots.value.count == 1)
    #expect(fixture.recordings.value.count == 1)
    #expect(fixture.previews.attachments.count == attachments, "An ignored preview command must not run later")
    await pane.close()
    await fixture.close()
  }

  @Test
  func metadataUpdatesKeepAttachmentsAndWindowSelection() async throws {
    let fixture = Fixture()
    let pane = fixture.pane()
    AppSettings.shared.lastViewedDeviceID = "B"
    let other = fixture.pane()
    await fixture.start(pane, other)
    let attachment = try #require(other.livePreviewAttachment(for: "B"))
    let original = try #require(fixture.devices.inventory.connected?.last)
    let renamed = Device(
      id: original.id, model: "Renamed", androidVersion: "16",
      vendorModel: nil, manufacturer: nil, avdName: nil, connection: original.connection
    )
    fixture.devices.inventory.connected = (fixture.devices.inventory.connected ?? []).map {
      $0.id == renamed.id ? renamed : $0
    }
    try await waitForState { other.currentPreview?.device.model == "Renamed" }
    #expect(other.livePreviewAttachment(for: "B") === attachment)
    #expect(pane.selectedPreviewDeviceID == "A")
    #expect(AppSettings.shared.lastViewedDeviceID == "B", "Other windows must not rewrite a saved selection")
    await pane.close()
    await other.close()
    await fixture.close()
  }
}
