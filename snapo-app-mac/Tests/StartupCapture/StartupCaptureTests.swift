import Foundation
import SnapODeviceClient

@main
@MainActor
struct StartupCaptureTests {
  static let options = LivePreviewOptions(showsTouches: false)
  static let first = testDevice("first")
  static let second = testDevice("second")

  static func main() async throws {
    await screenshotReuse()
    await screenshotFreshness()
    await livePreviewClaim()
    await changedPreviewOptions()
    await modeSwitchWaitsForCleanup()
    await unusedPreviewExpires()
    await cancelledClaimCleansUp()
    await discardSharesCleanup()
    try await managerReusesWarmup()
    try await managerDiscardsWrongDevice()
    await stopDuringRendererClaim()
    await disconnectWaitsForCleanup()
    await overlappingDeviceUpdates()
    await commandDuringAutomaticPreview(recordsVideo: true)
    await commandDuringAutomaticPreview(recordsVideo: false)
    await tearDownDuringQueuedCommand(recordsVideo: true)
    await tearDownDuringQueuedCommand(recordsVideo: false)
    await disconnectDuringQueuedCommand()
    await commandAfterPreparedPreviewReady()
    await cancelledQueuedCommand()
    print("Startup capture tests passed (20 cases)")
  }

  static func eventually(_ message: String = "Condition did not become true", _ condition: () async -> Bool) async {
    for _ in 0 ..< 10000 {
      if await condition() { return }
      await Task.yield()
    }
    fatalError(message)
  }

  static func prepare(
    _ service: LivePreviewService,
    device: Device = first,
    lifetime: Duration = .seconds(5)
  ) -> PreparedLivePreview {
    PreparedLivePreview(
      deviceID: device.id,
      options: options,
      operationTask: Task { try? await service.start(for: device.id, options: options) },
      service: service,
      lifetime: lifetime
    )
  }

  static func screenshots(
    service: ScreenshotService,
    devices: [Device],
    preload: Task<ScreenshotCaptureResult, Never>
  ) async -> ScreenshotCaptureResult {
    var mode: PreparingScreenshotMode?
    let result: ScreenshotCaptureResult = await withCheckedContinuation { continuation in
      mode = PreparingScreenshotMode(screenshotService: service, devices: devices, preloadedTask: preload) {
        continuation.resume(returning: $0)
      }
      mode?.start()
    }
    mode?.cancel()
    return result
  }

  static func screenshotReuse() async {
    let gate = TestGate()
    let service = ScreenshotService(gate: gate)
    let startup = StartupCapturePreparation(screenshots: service, livePreview: LivePreviewService())
    startup.prepare(mode: .screenshot, devices: [first], liveOptions: options)
    await eventually { await service.requests.count == 1 }
    startup.prepare(mode: .screenshot, devices: [first], liveOptions: options)
    guard let task = startup.claimScreenshots(for: [first]) else { fatalError("Missing screenshot preload") }
    precondition(startup.claimScreenshots(for: [first]) == nil)
    await gate.open()
    let result = await screenshots(service: service, devices: [first], preload: task)
    precondition(result.media.map(\.device.id) == [first.id])
    let requests = await service.requests
    precondition(requests == [[first.id]])
  }

  static func screenshotFreshness() async {
    let service = ScreenshotService()
    let fresh = testCapture(first)
    let stale = testCapture(second, age: 10)
    let result = await screenshots(service: service, devices: [first, second], preload: Task {
      ScreenshotCaptureResult(media: [fresh, stale], failures: [])
    })
    precondition(result.media.first?.id == fresh.id)
    precondition(result.media.last?.id != stale.id)
    let requests = await service.requests
    precondition(requests == [[second.id]])
  }

  static func livePreviewClaim() async {
    let service = LivePreviewService()
    let startup = StartupCapturePreparation(screenshots: ScreenshotService(), livePreview: service)
    startup.prepare(mode: .livePreview, devices: [first, second], liveOptions: options)
    await eventually { await service.starts.count == 1 }
    guard let prepared = startup.claimLivePreview(for: first, options: options),
          let handle = await prepared.take() else { fatalError("Missing live preload") }
    precondition(startup.claimLivePreview(for: first, options: options) == nil)
    let duplicate = await prepared.take()
    precondition(duplicate == nil)
    await startup.discard()
    await prepared.discard()
    let active = await service.active
    precondition(active == [handle.id])
    let starts = await service.starts
    precondition(starts == [first.id])
    _ = await service.stop(handle)
  }

  static func modeSwitchWaitsForCleanup() async {
    let startGate = TestGate()
    let stopGate = TestGate()
    let live = LivePreviewService(startGate: startGate, stopGate: stopGate)
    let shots = ScreenshotService()
    let startup = StartupCapturePreparation(screenshots: shots, livePreview: live)
    startup.prepare(mode: .livePreview, devices: [first], liveOptions: options)
    await eventually { await live.starts.count == 1 }
    startup.prepare(mode: .screenshot, devices: [first], liveOptions: options)
    guard let screenshotTask = startup.claimScreenshots(for: [first]) else { fatalError("Missing screenshot task") }
    await startGate.open()
    await eventually { await live.stops.count == 1 }
    let before = await shots.requests
    precondition(before.isEmpty)
    await stopGate.open()
    _ = await screenshotTask.value
    let active = await live.active
    precondition(active.isEmpty)
  }

  static func changedPreviewOptions() async {
    let service = LivePreviewService()
    let startup = StartupCapturePreparation(screenshots: ScreenshotService(), livePreview: service)
    startup.prepare(mode: .livePreview, devices: [first], liveOptions: options)
    await eventually { await service.active.count == 1 }
    let changed = LivePreviewOptions(showsTouches: true)
    guard let prepared = startup.claimLivePreview(for: first, options: changed),
          let handle = await prepared.take() else { fatalError("Missing replacement preview") }
    precondition(prepared.options == changed)
    let starts = await service.starts
    let active = await service.active
    precondition(starts == [first.id, first.id] && active == [handle.id])
    _ = await service.stop(handle)
  }

  static func unusedPreviewExpires() async {
    let service = LivePreviewService()
    let prepared = prepare(service, lifetime: .milliseconds(1))
    try? await Task.sleep(for: .milliseconds(10))
    await prepared.discard()
    let handle = await prepared.take()
    let active = await service.active
    precondition(handle == nil && active.isEmpty)
  }

  static func cancelledClaimCleansUp() async {
    let gate = TestGate()
    let service = LivePreviewService(startGate: gate)
    let prepared = prepare(service)
    let take = Task { await prepared.take() }
    await eventually { !prepared.isAvailable }
    take.cancel()
    await gate.open()
    let result = await take.value
    let active = await service.active
    precondition(result == nil && active.isEmpty)
  }

  static func discardSharesCleanup() async {
    let stopGate = TestGate()
    let readyGate = TestGate()
    let service = LivePreviewService(stopGate: stopGate, readyGate: readyGate)
    let prepared = prepare(service)
    await eventually { await service.active.count == 1 }
    let readiness = Task { await prepared.waitUntilReady() }
    let firstDiscard = Task { await prepared.discard() }
    await eventually { await service.stops.count == 1 }

    var secondDiscardFinished = false
    let secondDiscard = Task {
      await prepared.discard()
      secondDiscardFinished = true
    }
    var takeFinished = false
    let take = Task {
      let result = await prepared.take()
      takeFinished = true
      return result
    }

    await readyGate.open()
    let media = await readiness.value
    precondition(media == nil && !prepared.isAvailable)
    for _ in 0 ..< 20 {
      await Task.yield()
    }
    precondition(!secondDiscardFinished && !takeFinished)

    await stopGate.open()
    await firstDiscard.value
    await secondDiscard.value
    let result = await take.value
    let stops = await service.stops
    let active = await service.active
    precondition(result == nil && stops.count == 1 && active.isEmpty)
  }

  static func managerReusesWarmup() async throws {
    let slowDisplay = TestGate()
    let service = LivePreviewService()
    let prepared = prepare(service)
    var displayed: [String] = []
    let manager = LivePreviewManager(
      livePreviewService: service,
      adbService: ADBService(displayGates: [second.id: slowDisplay]),
      options: options,
      preparedLivePreview: prepared
    ) { displayed = $0.map(\.device.id) }
    let start = Task { await manager.start(with: [first, second]) }
    await eventually { displayed.contains(first.id) }
    precondition(!displayed.contains(second.id))
    let renderer = try await manager.makeRenderer(for: first.id)
    let starts = await service.starts
    precondition(starts == [first.id])
    await slowDisplay.open()
    await start.value
    await manager.stopRenderer(renderer)
    await manager.stop()
    let active = await service.active
    precondition(active.isEmpty)
  }

  static func managerDiscardsWrongDevice() async throws {
    let service = LivePreviewService()
    let manager = LivePreviewManager(
      livePreviewService: service, adbService: ADBService(), options: options,
      preparedLivePreview: prepare(service)
    ) { _ in }
    await manager.start(with: [first, second])
    let renderer = try await manager.makeRenderer(for: second.id)
    let active = await service.active
    precondition(active == [renderer.operation.id])
    let starts = await service.starts
    precondition(starts == [first.id, second.id])
    await manager.stop()
  }

  static func disconnectWaitsForCleanup() async {
    let stopGate = TestGate()
    let service = LivePreviewService(stopGate: stopGate)
    let manager = LivePreviewManager(
      livePreviewService: service, adbService: ADBService(), options: options,
      preparedLivePreview: prepare(service)
    ) { _ in }
    await manager.start(with: [first])
    let disconnect = Task { await manager.updateDevices([]) }
    await eventually { await service.stops.count == 1 }
    var stopped = false
    let stop = Task { await manager.stop()
      stopped = true
    }
    for _ in 0 ..< 20 {
      await Task.yield()
    }
    precondition(!stopped)
    await stopGate.open()
    await disconnect.value
    await stop.value
    let active = await service.active
    precondition(stopped && active.isEmpty)
  }

  static func stopDuringRendererClaim() async {
    let gate = TestGate()
    let service = LivePreviewService(startGate: gate)
    let prepared = prepare(service)
    let manager = LivePreviewManager(
      livePreviewService: service, adbService: ADBService(), options: options,
      preparedLivePreview: prepared
    ) { _ in }
    await manager.start(with: [first])
    let renderer = Task { try? await manager.makeRenderer(for: first.id) }
    await eventually { !prepared.isAvailable }
    var stopped = false
    let stop = Task { await manager.stop()
      stopped = true
    }
    for _ in 0 ..< 20 {
      await Task.yield()
    }
    precondition(!stopped)
    await gate.open()
    let result = await renderer.value
    await stop.value
    let active = await service.active
    precondition(result == nil && stopped && active.isEmpty)
  }

  static func overlappingDeviceUpdates() async {
    let gate = TestGate()
    var displayed: [String] = []
    let manager = LivePreviewManager(
      livePreviewService: LivePreviewService(), adbService: ADBService(displayGates: [first.id: gate]),
      options: options, preparedLivePreview: nil
    ) { displayed = $0.map(\.device.id) }
    let start = Task { await manager.start(with: [first]) }
    for _ in 0 ..< 20 {
      await Task.yield()
    }
    await manager.updateDevices([second])
    await gate.open()
    await start.value
    precondition(displayed == [second.id])
    await manager.stop()
  }

  @MainActor
  struct ControllerFixture {
    let displayGate = TestGate()
    let readyGate = TestGate()
    let stopGate = TestGate()
    let screenshots = ScreenshotService()
    let recording = RecordingService()
    let tracker = DeviceTracker(devices: [first])
    let live: LivePreviewService
    let controller: CaptureWindowController

    init() {
      AppSettings.shared.startupCaptureMode = .livePreview
      live = LivePreviewService(stopGate: stopGate, readyGate: readyGate)
      controller = CaptureWindowController(
        captureServices: CaptureServices(
          screenshots: screenshots,
          recording: recording,
          livePreview: live,
          startup: StartupCapturePreparation(screenshots: screenshots, livePreview: live)
        ),
        deviceTracker: tracker,
        fileStore: FileStore(),
        adbService: ADBService(displayGates: [first.id: displayGate])
      )
    }

    func start() async {
      await controller.start()
      await eventually { await displayGate.waitCount > 0 }
      await eventually { await readyGate.waitCount > 0 }
      precondition(controller.isLivePreviewActive && controller.isProcessing)
    }

    func request(recordsVideo: Bool) async -> Task<Void, Never> {
      var didStart = false
      let task = Task {
        didStart = true
        if recordsVideo {
          await controller.startRecording()
        } else {
          await controller.captureScreenshots()
        }
      }
      await eventually { didStart }
      return task
    }

    func assertNoCaptureRequests() async {
      let recordings = await recording.requests
      let captures = await screenshots.requests
      precondition(recordings.isEmpty && captures.isEmpty)
    }
  }

  static func commandDuringAutomaticPreview(recordsVideo: Bool) async {
    let fixture = ControllerFixture()
    await fixture.start()
    let command = await fixture.request(recordsVideo: recordsVideo)
    await fixture.assertNoCaptureRequests()

    await fixture.displayGate.open()
    await eventually("The explicit command must stop the automatic preview") { await fixture.live.stops.count == 1 }
    await fixture.assertNoCaptureRequests()
    await fixture.stopGate.open()
    await command.value

    if recordsVideo {
      await eventually { await fixture.recording.requests == [[first.id]] }
      precondition(fixture.controller.isRecording)
    } else {
      await eventually { await fixture.screenshots.requests == [[first.id]] }
      await eventually { !fixture.controller.isProcessing }
      guard case .image = fixture.controller.currentCapture?.media else {
        fatalError("Expected the explicit screenshot after automatic preview startup")
      }
    }
    let active = await fixture.live.active
    precondition(active.isEmpty)
    await fixture.controller.tearDown()
  }

  static func tearDownDuringQueuedCommand(recordsVideo: Bool) async {
    let fixture = ControllerFixture()
    await fixture.start()
    let command = await fixture.request(recordsVideo: recordsVideo)
    await fixture.stopGate.open()
    await fixture.controller.tearDown()
    await fixture.displayGate.open()
    await command.value
    await fixture.assertNoCaptureRequests()
    precondition(!fixture.controller.isRecording && !fixture.controller.isLivePreviewActive)
  }

  static func disconnectDuringQueuedCommand() async {
    let fixture = ControllerFixture()
    await fixture.start()
    let command = await fixture.request(recordsVideo: true)
    await fixture.tracker.updateDevices([])
    await eventually { !fixture.controller.hasDevices }
    await fixture.stopGate.open()
    await fixture.displayGate.open()
    await command.value
    await fixture.assertNoCaptureRequests()
    await fixture.controller.tearDown()
  }

  static func commandAfterPreparedPreviewReady() async {
    let fixture = ControllerFixture()
    await fixture.start()
    await fixture.readyGate.open()
    await eventually { fixture.controller.canStartRecordingNow }
    let command = await fixture.request(recordsVideo: true)
    await fixture.stopGate.open()
    await eventually { await fixture.recording.requests == [[first.id]] }
    await command.value
    precondition(fixture.controller.isRecording)
    await fixture.displayGate.open()
    await fixture.controller.tearDown()
  }

  static func cancelledQueuedCommand() async {
    let fixture = ControllerFixture()
    await fixture.start()
    let command = await fixture.request(recordsVideo: false)
    command.cancel()
    await fixture.displayGate.open()
    await command.value
    await fixture.assertNoCaptureRequests()
    await fixture.stopGate.open()
    await fixture.controller.tearDown()
  }
}
