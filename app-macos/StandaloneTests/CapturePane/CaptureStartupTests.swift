import Foundation
import Testing

extension CapturePaneTests {
  @Test(arguments: [false, true])
  func recordingWaitsForReadyDevices(readinessKnown: Bool) async throws {
    let fixture = Fixture()
    fixture.devices.inventory.ready = readinessKnown ? [] : nil
    let pane = fixture.pane()
    await fixture.start(pane)

    #expect(!pane.canStartRecordingNow)
    pane.launch(.startRecording)
    #expect(fixture.recordings.value.isEmpty)
    pane.enqueue(.record)
    #expect(fixture.recordings.value.isEmpty)

    fixture.devices.inventory.ready = fixture.devices.inventory.connected
    try await waitForState { pane.recording != nil }
    #expect(fixture.recordings.value.count == 1, "The queued command must survive the wait for boot")
    await pane.close()
    await fixture.close()
  }

  @Test(arguments: [false, true])
  func recordingIncludesOnlyReadyDevices(queued: Bool) async throws {
    let fixture = Fixture()
    fixture.devices.inventory.ready = fixture.devices.inventory.connected?.filter { $0.id == "A" }
    let pane = fixture.pane()
    await fixture.start(pane)
    #expect(pane.canStartRecordingNow)
    if queued { pane.enqueue(.record) } else { pane.launch(.startRecording) }
    let batch = try #require(pane.recording)
    #expect(batch.items.map(\.device.id) == ["A"])
    await pane.close()
    await fixture.close()
  }

  @Test(arguments: [StartupCaptureMode.screenshot, .livePreview], [nil, SnapOCommand.capture, .record, .livepreview])
  func startupCommandTakesPriorityWithoutDuplicateCapture(mode: StartupCaptureMode, command: SnapOCommand?) async throws {
    let fixture = Fixture()
    AppSettings.shared.startupCaptureMode = mode
    let available = fixture.devices.inventory
    fixture.devices.inventory = DeviceInventory()
    let pane = fixture.pane()
    if let command { pane.enqueue(command) }
    await pane.start()
    await pane.start()
    #expect(fixture.screenshots.value.isEmpty && fixture.recordings.value.isEmpty)
    fixture.devices.inventory = available
    let expected = command ?? (mode == .screenshot ? .capture : .livepreview)
    switch expected {
    case .capture:
      try await waitForState { pane.review != nil }
      #expect(fixture.screenshots.value.count == 1 && fixture.recordings.value.isEmpty)
      #expect(fixture.previews.attachments.isEmpty)
    case .record:
      try await waitForState { pane.recording?.phase == .recording }
      #expect(fixture.recordings.value.count == 1 && fixture.screenshots.value.isEmpty)
    case .livepreview:
      try await waitForState { pane.currentPreview != nil }
      #expect(fixture.screenshots.value.isEmpty && fixture.recordings.value.isEmpty)
    }
    await pane.close()
    await fixture.close()
  }

  @Test(arguments: [false, true])
  func previewCommandCannotPassScreenshotWaitingForBoot(sendAfterStart: Bool) async throws {
    let fixture = Fixture()
    let connected = fixture.devices.inventory.connected
    fixture.devices.inventory = DeviceInventory()
    let pane = fixture.pane()
    pane.enqueue(.capture)
    if !sendAfterStart { pane.enqueue(.livepreview) }
    await pane.start()
    fixture.devices.inventory.connected = connected
    if sendAfterStart { pane.enqueue(.livepreview) }
    #expect(fixture.screenshots.value.isEmpty)
    #expect(pane.previews.isEmpty, "The queued screenshot takes priority over preview startup")
    #expect(fixture.previews.attachments.isEmpty)
    fixture.devices.inventory.ready = connected
    try await waitForState { fixture.screenshots.value.count == 1 }
    #expect(pane.currentPreview != nil, "The later preview command runs after the screenshot starts")
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
    pane.enqueue(.livepreview)
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
  func closingDropsACommandWaitingForDevices() async {
    let fixture = Fixture()
    let available = fixture.devices.inventory
    fixture.devices.inventory = DeviceInventory()
    let pane = fixture.pane()
    pane.enqueue(.capture)
    await pane.start()
    await pane.close()
    fixture.devices.inventory = available
    pane.enqueue(.record)
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
    pane.enqueue(.record)
    try await waitForState { pane.recording?.phase == .recording }
    let batch = try #require(pane.recording)
    #expect(pane.livePreviewAttachment(for: "A") === attachment)
    #expect(!attachment.isClosed)
    pane.enqueue(.capture)
    pane.enqueue(.livepreview)
    #expect(pane.recording === batch && fixture.screenshots.value.isEmpty)
    pane.stopRecording()
    #expect(pane.review?.batch === batch)
    #expect(batch.phase == .finishing)
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
