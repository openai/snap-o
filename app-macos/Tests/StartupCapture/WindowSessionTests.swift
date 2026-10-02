import AppKit
import Foundation

@MainActor
enum WindowSessionTests {
  static let devices = [testDevice("window-first"), testDevice("window-second")]

  static func run() async throws {
    _ = NSApplication.shared
    for command in [SnapOCommand.capture, .record, .livepreview] {
      await hiddenLaunchWindowCanBeReused(command: command)
    }
    await hiddenLaunchWindowCanBeReused(command: .livepreview, opensDevice: true)
    try await remountPreservesSession()
    await closeDuringStartupIsFinal()
    try await capturesExcludeOtherWindows()
    await closingCaptureWaitsForCleanup(recordsVideo: false)
    await closingCaptureWaitsForCleanup(recordsVideo: true)
    await startupCaptureCanBeClaimedWhileBusy()
    await explicitCommandReplacesStartupCapture()
    await openDeviceWaitsWithoutStartingDefaultCapture()
    print("Window session tests passed")
  }

  @MainActor
  struct Fixture {
    let coordinator = CaptureCoordinator()
    let tracker: DeviceManager
    let screenshots: ScreenshotService
    let recording: RecordingService
    let live = LivePreviewService()
    let startup: StartupCapturePreparation
    let adb = ADBService()

    init(devices: [Device] = WindowSessionTests.devices, screenshotGate: TestGate? = nil) {
      AppSettings.shared.startupCaptureMode = .livePreview
      AppSettings.shared.recordAsBugReport = false
      tracker = DeviceManager(devices: devices)
      screenshots = ScreenshotService(gate: screenshotGate, coordinator: coordinator)
      recording = RecordingService(coordinator: coordinator)
      startup = StartupCapturePreparation(screenshots: screenshots, livePreview: live)
    }

    func session() -> CaptureWindowSession {
      let controller = CaptureWindowController(
        captureServices: CaptureServices(
          coordinator: coordinator, screenshots: screenshots, recording: recording, livePreview: live, startup: startup
        ),
        deviceManager: tracker, fileStore: FileStore(), adbService: adb
      )
      return CaptureWindowSession(
        controller: controller, tools: ToolSession(adbService: adb, deviceManager: tracker), deviceManager: tracker
      )
    }
  }

  static func window(for session: CaptureWindowSession) -> NSWindow {
    let window = NSWindow(
      contentRect: NSRect(x: -10000, y: -10000, width: 1, height: 1), styleMask: [.titled], backing: .buffered, defer: false
    )
    window.isReleasedWhenClosed = false
    window.contentView = NSView()
    mount(session, in: window)
    window.orderFront(nil)
    session.attach(to: window)
    return window
  }

  static func mount(_ session: CaptureWindowSession, in window: NSWindow) {
    window.contentView?.subviews.forEach { $0.removeFromSuperview() }
    let view = WindowCommandTargetView(
      perform: { session.perform($0) }, openDevice: { session.openDevice($0) },
      attached: { session.attach(to: $0) }, thumbnail: { _ in nil }
    )
    window.contentView?.addSubview(view)
  }

  static func hiddenLaunchWindowCanBeReused(command: SnapOCommand, opensDevice: Bool = false) async {
    let fixture = Fixture()
    let session = fixture.session()
    session.updateTools(true)
    let url = opensDevice ? DeviceOpenRequest.serial(devices[1].id).url! : URL(string: "snapo://\(command.rawValue)")!
    precondition(SnapOCommandCoordinator.shared.handle(url: url))
    let window = NSWindow(
      contentRect: NSRect(x: -10000, y: -10000, width: 1, height: 1), styleMask: [.titled], backing: .buffered, defer: false
    )
    window.isReleasedWhenClosed = false
    window.contentView = NSView()
    mount(session, in: window)
    precondition(!window.isVisible, "Registering must not show SwiftUI's unfinished launch window")
    window.close()
    precondition(!session.isClosed && session.tools.model == nil, "A hidden launch window has not started its session")
    mount(session, in: window)
    window.orderFront(nil)
    NotificationCenter.default.post(name: NSWindow.didUpdateNotification, object: window)
    await StartupCaptureTests.eventually {
      switch command {
      case .capture: session.controller.isReviewingCapture
      case .record: session.controller.isRecording
      case .livepreview:
        session.controller.isLivePreviewActive && !session.controller.isProcessing
          && (!opensDevice || session.controller.currentCapture?.device.id == devices[1].id)
      }
    }
    precondition(session.tools.model != nil)
    window.close()
    precondition(session.isClosed)
    await session.close().value
  }

  static func remountPreservesSession() async throws {
    let fixture = Fixture(devices: [])
    let session = fixture.session()
    session.updateTools(true)
    session.perform(.livepreview)
    let window = window(for: session)
    await StartupCaptureTests.eventually { session.controller.isDeviceListInitialized }
    let model = session.tools.model
    precondition(model != nil)
    for _ in 0 ..< 3 {
      mount(session, in: window)
    }
    precondition(session.tools.model === model && !session.isClosed, "Remounting must preserve the tool session")
    fixture.tracker.updateDevices(devices)
    await StartupCaptureTests.eventually { session.controller.isLivePreviewActive && !session.controller.isProcessing }
    let renderer = await session.controller.startLivePreviewStream(for: devices[0].id)
    precondition(renderer != nil)
    let other = fixture.session()
    let otherWindow = self.window(for: other)
    await StartupCaptureTests.eventually { other.controller.isLivePreviewActive && !other.controller.isProcessing }
    let otherRenderer = await other.controller.startLivePreviewStream(for: devices[0].id)
    precondition(otherRenderer != nil)
    let history = CaptureHistoryRepository()
    let captureID = UUID()
    session.protectCaptures([captureID], in: history)
    await StartupCaptureTests.eventually { await history.protections.values.contains([captureID]) }
    mount(session, in: window)
    session.openDevice(.serial(devices[1].id))
    await StartupCaptureTests.eventually { session.controller.currentCapture?.device.id == devices[1].id }
    precondition(session.tools.model === model)
    window.close()
    precondition(session.isClosed, "Only the real window close should close the session")
    await session.close().value
    let active = await fixture.live.active
    precondition(active.contains(otherRenderer!.operation.id), "Closing one window must preserve another window's preview")
    precondition(!active.contains(renderer!.operation.id))
    precondition(model!.isStopped && model!.service.isStopped)
    let protections = await history.protections
    precondition(protections.isEmpty)
    otherWindow.close()
    await other.close().value
  }

  static func closeDuringStartupIsFinal() async {
    let fixture = Fixture(devices: [])
    let session = fixture.session()
    session.perform(.record)
    session.openDevice(.serial(devices[0].id))
    let window = window(for: session)
    window.close()
    await session.close().value
    session.attach(to: window)
    session.updateTools(true)
    session.perform(.capture)
    session.openDevice(.serial(devices[1].id))
    fixture.tracker.updateDevices(devices)
    await session.controller.start()
    await session.controller.perform(.record)
    precondition(session.controller.deviceOpenRequest == nil && session.tools.model == nil)
    let recordings = await fixture.recording.requests
    let screenshots = await fixture.screenshots.requests
    precondition(recordings.isEmpty && screenshots.isEmpty, "Closed sessions cannot restart or accept commands")
  }

  static func capturesExcludeOtherWindows() async throws {
    let gate = TestGate()
    let fixture = Fixture(screenshotGate: gate)
    let first = fixture.session()
    let second = fixture.session()
    let firstWindow = window(for: first)
    let secondWindow = window(for: second)
    await StartupCaptureTests.eventually { first.controller.isLivePreviewActive && !first.controller.isProcessing }
    await StartupCaptureTests.eventually { second.controller.isLivePreviewActive && !second.controller.isProcessing }
    await first.controller.perform(.record)
    await StartupCaptureTests.eventually { fixture.coordinator.captureActivity == .recording }
    precondition(!second.controller.canCaptureNow && !second.controller.canStartRecordingNow)
    precondition(second.controller.isLivePreviewActive)
    await second.controller.perform(.capture)
    await second.controller.perform(.record)
    let screenshots = await fixture.screenshots.requests
    let recordings = await fixture.recording.requests
    precondition(screenshots.isEmpty && recordings.count == 1)
    let stopGate = TestGate()
    await fixture.recording.blockFinish(on: stopGate)
    let stopping = await startTestTask { await first.controller.stopRecording() }
    await StartupCaptureTests.eventually { await stopGate.waitCount == 1 }
    precondition(!second.controller.canCaptureNow, "Stopping is still part of the capture")
    await stopGate.open()
    await stopping.value
    await StartupCaptureTests.eventually { second.controller.canCaptureNow }
    await second.controller.perform(.capture)
    await StartupCaptureTests.eventually { await gate.waitCount == 1 }
    precondition(!first.controller.canCaptureNow && !first.controller.canStartRecordingNow)
    await gate.open()
    await StartupCaptureTests.eventually { second.controller.isReviewingCapture }
    precondition(first.controller.canCaptureNow, "Reviewing a result must not block another window")
    firstWindow.close()
    secondWindow.close()
    await first.close().value
    await second.close().value
    precondition(!fixture.coordinator.isCapturing)
  }

  static func closingCaptureWaitsForCleanup(recordsVideo: Bool) async {
    let gate = TestGate()
    let fixture = Fixture(screenshotGate: gate)
    let session = fixture.session()
    let other = fixture.session()
    let window = window(for: session)
    let otherWindow = self.window(for: other)
    await StartupCaptureTests.eventually { session.controller.isLivePreviewActive && !session.controller.isProcessing }
    await StartupCaptureTests.eventually { other.controller.isLivePreviewActive && !other.controller.isProcessing }
    if recordsVideo { await fixture.recording.blockFinish(on: gate) }
    await session.controller.perform(recordsVideo ? .record : .capture)
    await StartupCaptureTests.eventually { fixture.coordinator.isCapturing }
    window.close()
    let closed = TestValue(false)
    let closing = await startTestTask {
      await session.close().value
      closed.value = true
    }
    await StartupCaptureTests.eventually { await gate.waitCount == 1 }
    precondition(!closed.value && !other.controller.canCaptureNow)
    session.perform(.record)
    session.attach(to: window)
    await gate.open()
    await closing.value
    await StartupCaptureTests.eventually { other.controller.canCaptureNow }
    precondition(session.isClosed && !session.controller.isRecording)
    let requests = await fixture.recording.requests
    precondition(requests.count == (recordsVideo ? 1 : 0), "Closing must reject later requests")
    otherWindow.close()
    await other.close().value
  }

  static func startupCaptureCanBeClaimedWhileBusy() async {
    let gate = TestGate()
    let fixture = Fixture(screenshotGate: gate)
    AppSettings.shared.startupCaptureMode = .screenshot
    fixture.startup.prepare(mode: .screenshot, devices: devices, liveOptions: LivePreviewOptions(showsTouches: false))
    await StartupCaptureTests.eventually { await gate.waitCount == 1 }
    let session = fixture.session()
    let window = window(for: session)
    await StartupCaptureTests.eventually { session.controller.isProcessing }
    await gate.open()
    await StartupCaptureTests.eventually { session.controller.isReviewingCapture }
    let requests = await fixture.screenshots.requests
    precondition(requests.count == 1, "Claiming startup work must not acquire a second capture")
    window.close()
    await session.close().value
  }

  static func openDeviceWaitsWithoutStartingDefaultCapture() async {
    let fixture = Fixture(devices: [devices[0]])
    AppSettings.shared.startupCaptureMode = .screenshot
    let session = fixture.session()
    session.openDevice(.serial(devices[1].id))
    let window = window(for: session)
    await StartupCaptureTests.eventually { session.controller.isDeviceListInitialized }
    precondition(!session.controller.isProcessing && !session.controller.isReviewingCapture)
    let requests = await fixture.screenshots.requests
    precondition(requests.isEmpty, "A specific-device request must take priority over automatic screenshots")
    window.close()
    await session.close().value
  }

  static func explicitCommandReplacesStartupCapture() async {
    let gate = TestGate()
    let fixture = Fixture(screenshotGate: gate)
    AppSettings.shared.startupCaptureMode = .screenshot
    fixture.startup.prepare(mode: .screenshot, devices: devices, liveOptions: LivePreviewOptions(showsTouches: false))
    await StartupCaptureTests.eventually { await gate.waitCount == 1 }
    let session = fixture.session()
    let command = await startTestTask { await session.controller.perform(.record) }
    let window = window(for: session)
    await gate.open()
    await command.value
    await StartupCaptureTests.eventually { fixture.coordinator.captureActivity == .recording }
    let requests = await fixture.recording.requests
    precondition(requests.count == 1)
    window.close()
    await session.close().value
  }
}
