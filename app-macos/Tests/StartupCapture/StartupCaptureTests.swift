import Foundation

@main
@MainActor
struct StartupCaptureTests {
  static let options = LivePreviewOptions(showsTouches: false)
  static let first = testDevice("first")
  static let second = testDevice("second")

  static func main() async throws {
    try await CaptureModeTests.run()
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
    try await managerRetriesBootingDevice(densityUnavailable: false)
    try await managerRetriesBootingDevice(densityUnavailable: true)
    await displayRetryCancellation(stops: false)
    await displayRetryCancellation(stops: true)
    try await deviceBootsAfterWindowOpens()
    await discoveryWaitsForBootComplete()
    await discoveryBacksOffStalledDevice()
    await stopDuringRendererClaim()
    await disconnectWaitsForCleanup()
    await commandDuringAutomaticPreview(recordsVideo: true)
    await commandDuringAutomaticPreview(recordsVideo: false)
    await tearDownDuringQueuedCommand(recordsVideo: true)
    await tearDownDuringQueuedCommand(recordsVideo: false)
    await disconnectDuringQueuedCommand()
    await commandAfterPreparedPreviewReady()
    await cancelledQueuedCommand()
    await commandDuringAutomaticPreview(recordsVideo: true, previewReadyFirst: true)
    await commandDuringAutomaticPreview(recordsVideo: false, previewReadyFirst: true)
    await captureHistoryDeletion(deletesCurrent: true)
    await captureHistoryDeletion(deletesCurrent: false)
    await captureHistoryDeletion(deletesCurrent: true, deletesAll: true)
    await captureHistoryDeletion(deletesCurrent: true, disconnects: true)
    await captureHistoryDeletion(deletesCurrent: true, managed: false)
    await deviceManagerOpenPreservesLaterSelection()
    await automaticPreviewRequiresReadyLivePreview()
    await automaticPreviewPreservesCapture(recordsVideo: false)
    await automaticPreviewPreservesCapture(recordsVideo: true)
    print("Startup capture tests passed (37 cases)")
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
    lifetime: Duration = .seconds(5),
    sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
  ) -> PreparedLivePreview {
    PreparedLivePreview(
      deviceID: device.id,
      options: options,
      operationTask: Task { try? await service.start(for: device.id, options: options) },
      service: service,
      lifetime: lifetime, sleep: sleep
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
    let expiration = TestGate()
    let prepared = prepare(service) { _ in await expiration.wait() }
    await eventually { await service.active.count == 1 }
    await eventually { await expiration.waitCount == 1 }
    precondition(prepared.isAvailable)
    await expiration.open()
    await eventually { !prepared.isAvailable }
    let handle = await prepared.take()
    let active = await service.active
    let stops = await service.stops
    precondition(handle == nil && active.isEmpty && stops.count == 1)
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

  static func managerRetriesBootingDevice(densityUnavailable: Bool) async throws {
    let retryGate = TestGate()
    let adb = ADBService(
      displayFailures: densityUnavailable ? [:] : [first.id: 2],
      densityFailures: densityUnavailable ? [first.id: 2] : [:]
    )
    let service = LivePreviewService()
    let failedWarmup = PreparedLivePreview(
      deviceID: first.id, options: options, operationTask: Task { nil }, service: service
    )
    var displayed: [String] = []
    let manager = LivePreviewManager(
      livePreviewService: service, adbService: adb, options: options,
      preparedLivePreview: failedWarmup,
      displayRetrySleep: { _ in await retryGate.wait() }
    ) { displayed = $0.map(\.device.id) }
    await manager.start(with: [first, second])
    precondition(displayed == [second.id], "A booting device must not block a ready device")
    await retryGate.open()
    await eventually("Retry must create media without another device update") { displayed == [first.id, second.id] }
    let requests = await adb.displayRequests
    precondition(requests.count(where: { $0 == first.id }) == 3)
    precondition(requests.count(where: { $0 == second.id }) == 1, "Ready devices must not be queried again")
    let renderer = try await manager.makeRenderer(for: first.id)
    await eventually { renderer.operation.session.isReady }
    let starts = await service.starts
    precondition(starts == [first.id], "A failed warmup must allow a fresh preview stream")
    await manager.stop()
  }

  static func discoveryWaitsForBootComplete() async {
    let retryGate = TestGate()
    let adb = ADBService()
    await adb.setBooting(true, deviceID: first.id)
    var displayed: [String] = []
    let manager = LivePreviewManager(
      livePreviewService: LivePreviewService(), adbService: adb, options: options,
      displayRetrySleep: { _ in await retryGate.wait() },
      mediaDidChange: { displayed = $0.map(\.device.id) }
    )
    await manager.start(with: [first, second])
    precondition(displayed == [second.id])
    let requestsBeforeBoot = await adb.displayRequests
    precondition(requestsBeforeBoot == [second.id], "Booting devices must not receive display queries")
    await adb.setBooting(false, deviceID: first.id)
    await retryGate.open()
    await eventually { displayed == [first.id, second.id] }
    await manager.stop()
  }

  static func discoveryBacksOffStalledDevice() async {
    let adb = ADBService(displayFailures: [first.id: 7])
    var displayed: [String] = []
    let manager = LivePreviewManager(
      livePreviewService: LivePreviewService(), adbService: adb, options: options,
      displayRetrySleep: { await adb.recordRetryDelay($0) },
      mediaDidChange: { displayed = $0.map(\.device.id) }
    )
    await manager.start(with: [first, second])
    await eventually { displayed == [first.id, second.id] }
    let delays = await adb.retryDelays
    precondition(delays == [1, 2, 4, 8, 10, 10, 10].map { .seconds($0) })
    let requests = await adb.displayRequests
    precondition(requests.count { $0 == second.id } == 1, "Healthy devices must not be rediscovered while another retries")
    await manager.stop()
  }

  static func deviceBootsAfterWindowOpens() async throws {
    AppSettings.shared.startupCaptureMode = .livePreview
    let tracker = DeviceTracker(devices: [])
    let live = LivePreviewService(startFailures: 1)
    let screenshots = ScreenshotService()
    let controller = CaptureWindowController(
      captureServices: CaptureServices(
        screenshots: screenshots, recording: RecordingService(), livePreview: live,
        startup: StartupCapturePreparation(screenshots: screenshots, livePreview: live)
      ),
      deviceTracker: tracker, fileStore: FileStore(),
      adbService: ADBService(displayFailures: [first.id: 3])
    )
    await controller.start()
    await eventually { controller.isDeviceListInitialized }
    precondition(!controller.hasDevices && controller.currentCapture == nil)
    await tracker.updateDevices([first])
    await eventually { controller.isLivePreviewActive }
    precondition(controller.currentCapture == nil)
    let deadline = ContinuousClock.now.advanced(by: .seconds(10))
    while controller.currentCapture == nil, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    precondition(controller.currentCapture?.device.id == first.id, "Preview must appear after boot without another device event")
    precondition(!controller.isProcessing)
    guard let renderer = await controller.startLivePreviewStream(for: first.id) else {
      fatalError("Preview must start after the boot-time warmup failed")
    }
    await eventually { renderer.operation.session.isReady }
    await controller.tearDown()
    let active = await live.active
    precondition(active.isEmpty)
  }

  static func displayRetryCancellation(stops: Bool) async {
    let retryGate = TestGate()
    let queryGate = TestGate()
    let adb = ADBService(displayFailures: [first.id: 1])
    var displayed: [String] = []
    let manager = LivePreviewManager(
      livePreviewService: LivePreviewService(), adbService: adb, options: options,
      displayRetrySleep: { _ in await retryGate.wait() },
      mediaDidChange: { displayed = $0.map(\.device.id) }
    )
    await manager.start(with: [first])
    await adb.setDisplayGate(queryGate, for: first.id)
    await retryGate.open()
    await eventually { await queryGate.waitCount == 1 }
    if stops {
      await manager.stop()
    } else {
      await manager.updateDevices([])
    }
    await queryGate.open()
    for _ in 0 ..< 100 {
      await Task.yield()
    }
    precondition(displayed.isEmpty, "A late display response must not restore a disconnected or stopped preview")
    let requests = await adb.displayRequests
    precondition(requests.count == 2, "Canceled discovery must not schedule more queries")
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

  @MainActor
  struct ControllerFixture {
    let displayGate = TestGate()
    let readyGate = TestGate()
    let stopGate = TestGate()
    let screenshots = ScreenshotService()
    let recording = RecordingService()
    let tracker: DeviceTracker
    let live: LivePreviewService
    let controller: CaptureWindowController

    init(devices: [Device] = [first], blockedDisplayDevice: Device = first) {
      AppSettings.shared.startupCaptureMode = .livePreview
      tracker = DeviceTracker(devices: devices)
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
        adbService: ADBService(displayGates: [blockedDisplayDevice.id: displayGate])
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

  static func deviceManagerOpenPreservesLaterSelection() async {
    let fixture = ControllerFixture(devices: [first, second])
    await fixture.displayGate.open()
    await fixture.readyGate.open()
    await fixture.stopGate.open()
    let controller = fixture.controller
    await controller.start()
    await eventually { controller.mediaList.count == 2 && !controller.isProcessing }
    let firstMediaID = controller.mediaList.first { $0.device.id == first.id }?.id
    controller.selectMedia(id: firstMediaID)
    await eventually { controller.selectedDeviceID == first.id }
    await controller.showLivePreview(deviceID: second.id)
    await eventually { controller.selectedDeviceID == second.id }
    controller.selectMedia(id: firstMediaID)
    await eventually { controller.selectedDeviceID == first.id }

    let third = testDevice("third")
    await fixture.tracker.updateDevices([first, second, third])
    await eventually { controller.mediaList.count == 3 }
    precondition(controller.selectedDeviceID == first.id, "Device Manager must not override a later selection")
    await controller.tearDown()
  }

  static func automaticPreviewRequiresReadyLivePreview() async {
    let fixture = ControllerFixture(devices: [first, second])
    let controller = fixture.controller
    precondition(!controller.selectDeviceInLivePreview(id: second.id))
    await fixture.start()
    precondition(!controller.selectDeviceInLivePreview(id: second.id), "Do not interrupt preview setup")
    await fixture.displayGate.open()
    await fixture.readyGate.open()
    await fixture.stopGate.open()
    await eventually { controller.mediaList.count == 2 && !controller.isProcessing }
    precondition(controller.selectDeviceInLivePreview(id: second.id))
    await eventually { controller.selectedDeviceID == second.id }
    precondition(controller.selectedDeviceID == second.id && controller.isLivePreviewActive)
    precondition(controller.lastError == nil)
    await controller.tearDown()
    precondition(!controller.selectDeviceInLivePreview(id: first.id))
  }

  static func automaticPreviewPreservesCapture(recordsVideo: Bool) async {
    let fixture = ControllerFixture(devices: [first, second])
    let controller = fixture.controller
    await fixture.displayGate.open()
    await fixture.readyGate.open()
    await controller.start()
    await eventually { controller.mediaList.count == 2 && !controller.isProcessing }
    controller.selectDevice(id: first.id)
    await eventually { controller.selectedDeviceID == first.id }
    let capture = await fixture.request(recordsVideo: recordsVideo)
    await eventually { await fixture.stopGate.waitCount > 0 }
    precondition(controller.isProcessing)
    precondition(!controller.selectDeviceInLivePreview(id: second.id), "Do not interrupt an active capture")
    await fixture.stopGate.open()
    await capture.value
    await eventually { !controller.isProcessing }
    precondition(!controller.selectDeviceInLivePreview(id: second.id))
    precondition(controller.lastError == nil && !controller.isLivePreviewActive)
    if recordsVideo {
      precondition(controller.isRecording)
    } else {
      guard let screenshot = controller.currentCapture else { fatalError("Missing completed screenshot") }
      precondition(screenshot.media.isImage && screenshot.device.id == first.id)
      let video = CaptureMedia(device: first, media: .video(
        url: URL(fileURLWithPath: "/tmp/recorded-preview-test.mp4"), data: screenshot.media.common
      ))
      controller.mediaDisplayMode.updateMediaList([video], preserveDeviceID: first.id, shouldSort: false)
      await eventually { controller.currentCapture?.id == video.id }
      precondition(!controller.selectDeviceInLivePreview(id: second.id), "Do not replace a recorded video")
      precondition(controller.currentCapture?.id == video.id && controller.lastError == nil)
      await controller.showLivePreview(deviceID: second.id)
      await eventually { controller.selectedDeviceID == second.id }
      precondition(controller.isLivePreviewActive && controller.selectedDeviceID == second.id)
    }
    await controller.tearDown()
  }

  static func captureHistoryDeletion(
    deletesCurrent: Bool,
    deletesAll: Bool = false,
    disconnects: Bool = false,
    managed: Bool = true
  ) async {
    let fixture = ControllerFixture(devices: [first, second])
    AppSettings.shared.startupCaptureMode = .screenshot
    await fixture.displayGate.open()
    await fixture.readyGate.open()
    await fixture.stopGate.open()
    await fixture.controller.start()
    await eventually { fixture.controller.currentCapture?.media.isImage == true && !fixture.controller.isProcessing }
    let root = URL(fileURLWithPath: "/tmp/history-deletion-tests")
    let captureDirectory = (managed ? root : URL(fileURLWithPath: "/tmp/unsaved-captures", isDirectory: true))
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let captures = fixture.controller.mediaList.map { capture in
      CaptureMedia(id: capture.id, device: capture.device, media: .image(
        url: captureDirectory.appendingPathComponent("\(capture.id).png"), data: capture.media.common
      ))
    }
    fixture.controller.mediaDisplayMode.updateMediaList(captures, preserveDeviceID: second.id, shouldSort: false)
    let currentID = fixture.controller.currentCapture!.id
    let originalIDs = Set(captures.map(\.id))
    fixture.controller.synchronizeCaptureHistory(availableCaptureIDs: originalIDs, root: root)
    precondition(fixture.controller.currentCapture?.id == currentID && !fixture.controller.isLivePreviewActive)
    if disconnects {
      await fixture.tracker.updateDevices([])
      await eventually { !fixture.controller.hasDevices }
    }
    let remainingIDs: Set<UUID> = if deletesAll {
      []
    } else if deletesCurrent {
      originalIDs.subtracting([currentID])
    } else {
      [currentID]
    }
    fixture.controller.synchronizeCaptureHistory(availableCaptureIDs: remainingIDs, root: root)
    if !managed {
      precondition(Set(fixture.controller.mediaList.map(\.id)) == originalIDs, "Unsaved media is not part of history")
      precondition(fixture.controller.currentCapture?.id == currentID && !fixture.controller.isLivePreviewActive)
    } else if !deletesCurrent {
      precondition(fixture.controller.mediaList.map(\.id) == [currentID])
      precondition(fixture.controller.currentCapture?.id == currentID && !fixture.controller.isLivePreviewActive)
    } else if disconnects {
      precondition(fixture.controller.currentCapture == nil && fixture.controller.mediaList.isEmpty)
      precondition(!fixture.controller.isLivePreviewActive, "No device leaves the pane waiting, without deleted media")
    } else {
      await eventually { fixture.controller.isLivePreviewActive && !fixture.controller.isProcessing }
      precondition(fixture.controller.currentCapture?.device.id == second.id, "Live Preview keeps the selected device")
      precondition(Set(fixture.controller.mediaList.map(\.id)).isDisjoint(with: originalIDs))
      let previewID = fixture.controller.currentCapture?.id
      fixture.controller.synchronizeCaptureHistory(availableCaptureIDs: [], root: root)
      precondition(fixture.controller.currentCapture?.id == previewID, "History updates do not restart Live Preview")
    }
    await fixture.controller.tearDown()
  }

  static func commandDuringAutomaticPreview(recordsVideo: Bool, previewReadyFirst: Bool = false) async {
    let fixture = ControllerFixture(devices: [first, second], blockedDisplayDevice: second)
    await fixture.start()
    let command = await fixture.request(recordsVideo: recordsVideo)
    await fixture.assertNoCaptureRequests()

    if previewReadyFirst {
      await fixture.readyGate.open()
    } else {
      await fixture.displayGate.open()
    }
    await eventually("The explicit command must stop the automatic preview") { await fixture.live.stops.count == 1 }
    await fixture.assertNoCaptureRequests()
    await fixture.stopGate.open()
    await command.value

    if recordsVideo {
      await eventually { await fixture.recording.requests == [[first.id, second.id]] }
      precondition(fixture.controller.isRecording)
    } else {
      await eventually { await fixture.screenshots.requests == [[first.id, second.id]] }
      await eventually { !fixture.controller.isProcessing }
      guard case .image = fixture.controller.currentCapture?.media else {
        fatalError("Expected the explicit screenshot after automatic preview startup")
      }
    }
    let active = await fixture.live.active
    precondition(active.isEmpty)
    await fixture.displayGate.open()
    await fixture.controller.tearDown()
  }

  static func tearDownDuringQueuedCommand(recordsVideo: Bool) async {
    let fixture = ControllerFixture()
    await fixture.start()
    let command = await fixture.request(recordsVideo: recordsVideo)
    await fixture.stopGate.open()
    await fixture.controller.tearDown()
    await waitForCommand(command)
    await fixture.displayGate.open()
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
    await waitForCommand(command)
    await fixture.displayGate.open()
    await fixture.assertNoCaptureRequests()
    await fixture.stopGate.open()
    await fixture.controller.tearDown()
  }

  static func waitForCommand(_ command: Task<Void, Never>) async {
    var finished = false
    let completion = Task {
      await command.value
      finished = true
    }
    await eventually("The queued command must finish while display queries remain blocked") { finished }
    await completion.value
  }
}
