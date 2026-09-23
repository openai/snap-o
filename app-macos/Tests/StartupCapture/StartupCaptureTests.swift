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
    await earlyPreviewClaim()
    await earlyPreviewDiscard()
    await earlyPreviewReplacement()
    await changedPreviewOptions()
    await modeSwitchWaitsForCleanup()
    await unusedPreviewExpires()
    await cancelledClaimCleansUp()
    await discardSharesCleanup()
    try await managerReusesWarmup()
    try await emulatorFramesCreatePreviewBeforeBoot()
    try await unusedEmulatorWarmupReleasesStream()
    try await claimEmulatorBeforeFirstFrame()
    await overlappingDisplayDiscovery()
    await stoppingEmulatorBeforeFirstFrame()
    await emulatorReconnectDiscardsOldWarmup()
    try await emulatorInputWaitsForAndroid()
    try await rendererUsesLatestMediaAfterReadiness()
    await emulatorWarmupPreservesMatchingPreparedStream()
    try await managerRetriesBootingDevice(densityUnavailable: false)
    try await managerRetriesBootingDevice(densityUnavailable: true)
    await displayRetryCancellation(stops: false)
    await displayRetryCancellation(stops: true)
    try await deviceBootsAfterWindowOpens()
    await discoveryWaitsForBootComplete()
    await discoveryBacksOffStalledDevice()
    await stopDuringRendererClaim()
    await disconnectWaitsForCleanup()
    await reconnectDuringPreparedReadiness()
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
    await restoresPreferredDevice()
    await waitsForPreferredDeviceMedia()
    print("Startup capture tests passed")
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
    guard let prepared = await startup.claimLivePreview(for: first, options: options),
          let handle = await prepared.take() else { fatalError("Missing live preload") }
    let duplicateClaim = await startup.claimLivePreview(for: first, options: options)
    precondition(duplicateClaim == nil)
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

  static func earlyPreviewClaim() async {
    let service = LivePreviewService()
    let startup = StartupCapturePreparation(screenshots: ScreenshotService(), livePreview: service)
    startup.prepareEarlyPreview(options: options) { [id = second.id] in id }
    await eventually { await service.starts == [second.id] }
    startup.prepare(mode: .livePreview, devices: [first, second], liveOptions: options)
    guard let prepared = await startup.claimLivePreview(for: second, options: options),
          let operation = await prepared.take() else { fatalError("Missing early preview") }
    let starts = await service.starts
    precondition(starts == [second.id], "Properties arriving must not replace the preferred-device session")
    _ = await service.stop(operation)
    await startup.discard()
  }

  static func earlyPreviewDiscard() async {
    let gate = TestGate()
    let service = LivePreviewService(startGate: gate)
    let startup = StartupCapturePreparation(screenshots: ScreenshotService(), livePreview: service)
    startup.prepareEarlyPreview(options: options) { [id = first.id] in id }
    await eventually { await service.starts == [first.id] }
    let discard = Task { await startup.discard() }
    await gate.open()
    await discard.value
    let active = await service.active
    precondition(active.isEmpty, "Discard must clean up an early session still starting")
  }

  static func earlyPreviewReplacement() async {
    for changesDevice in [false, true] {
      let service = LivePreviewService()
      let startup = StartupCapturePreparation(screenshots: ScreenshotService(), livePreview: service)
      startup.prepareEarlyPreview(options: options) { [id = first.id] in id }
      await eventually { await service.active.count == 1 }
      let device = changesDevice ? second : first
      let desiredOptions = LivePreviewOptions(showsTouches: !changesDevice)
      guard let prepared = await startup.claimLivePreview(for: device, options: desiredOptions),
            let handle = await prepared.take() else { fatalError("Missing replacement") }
      precondition(handle.deviceID == device.id && prepared.options == desiredOptions)
      let stops = await service.stops
      let active = await service.active
      precondition(stops.count == 1 && active.count == 1, "Replacement must release the previous warmup")
      _ = await service.stop(handle)
      await startup.discard()
    }
  }

  static func changedPreviewOptions() async {
    let service = LivePreviewService()
    let startup = StartupCapturePreparation(screenshots: ScreenshotService(), livePreview: service)
    startup.prepare(mode: .livePreview, devices: [first], liveOptions: options)
    await eventually { await service.active.count == 1 }
    let changed = LivePreviewOptions(showsTouches: true)
    guard let prepared = await startup.claimLivePreview(for: first, options: changed),
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

  static func emulatorWarmupPreservesMatchingPreparedStream() async {
    let devices = [testDevice("emulator-5554"), testDevice("emulator-5556")]
    let service = LivePreviewService()
    var visible = 0
    let manager = LivePreviewManager(
      livePreviewService: service, adbService: ADBService(), options: options,
      preparedLivePreview: prepare(service, device: devices[1])
    ) { visible = $0.count }
    await manager.start(with: devices)
    await eventually { visible == 2 }
    let starts = await service.starts
    precondition(starts.count(where: { $0 == devices[1].id }) == 1, "The matching warmup must reuse the prepared stream")
    let renderer = try! await manager.makeRenderer(for: devices[1].id)
    let afterClaim = await service.starts
    precondition(afterClaim == starts, "Renderer must retain the warmed stream without reopening it")
    await manager.stopRenderer(renderer)
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
    await eventually("A booting device must not block a ready device") { displayed == [second.id] }
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

  static func emulatorFramesCreatePreviewBeforeBoot() async throws {
    let emulator = testDevice("emulator-5554")
    let adb = ADBService()
    await adb.setBooting(true, deviceID: emulator.id)
    let service = LivePreviewService()
    var captures: [CaptureMedia] = []
    let manager = LivePreviewManager(livePreviewService: service, adbService: adb, options: options) { captures = $0 }
    await manager.start(with: [emulator])
    await eventually { captures.count == 1 }
    precondition(captures[0].media.size == testDisplay.size)
    let requests = await adb.displayRequests
    precondition(requests.isEmpty, "First-frame sizing must not require Android display services")
    await manager.stop()
  }

  static func unusedEmulatorWarmupReleasesStream() async throws {
    let emulator = testDevice("emulator-5554")
    let service = LivePreviewService()
    var visible = false
    let expiration = TestGate()
    let manager = LivePreviewManager(
      livePreviewService: service,
      adbService: ADBService(),
      options: options,
      warmupSleep: { _ in await expiration.wait() }
    ) { visible = !$0.isEmpty }
    await manager.start(with: [emulator])
    await eventually { visible }
    let retained = await service.active
    precondition(retained.count == 1, "Warmup must remain available for renderer handoff")
    await expiration.open()
    await eventually { await service.active.isEmpty }
    let active = await service.active
    precondition(active.isEmpty, "Unused warmups must expire")
    let renderer = try await manager.makeRenderer(for: emulator.id)
    let starts = await service.starts
    precondition(starts == [emulator.id, emulator.id], "An expired warmup must allow a fresh renderer")
    await manager.stopRenderer(renderer)
    await manager.stop()
  }

  static func claimEmulatorBeforeFirstFrame() async throws {
    let emulator = testDevice("emulator-5554")
    let gate = TestGate()
    let expiration = TestGate()
    let service = LivePreviewService(readyGate: gate)
    let manager = LivePreviewManager(
      livePreviewService: service, adbService: ADBService(), options: options,
      warmupSleep: { _ in await expiration.wait() }
    ) { _ in }
    await manager.start(with: [emulator])
    await eventually { await gate.waitCount > 0 }
    let expirationWaits = await expiration.waitCount
    precondition(expirationWaits == 0, "Unused-warmup expiry must start after the first frame")
    let renderer = try await manager.makeRenderer(for: emulator.id)
    precondition(!renderer.operation.session.isReady)
    await gate.open()
    await eventually { renderer.operation.session.isReady }
    let starts = await service.starts
    precondition(starts == [emulator.id], "Claiming an unfinished warmup must retain its operation")
    await manager.stopRenderer(renderer)
    await manager.stop()
  }

  static func overlappingDisplayDiscovery() async {
    let gate = TestGate()
    let adb = ADBService(displayGates: [first.id: gate])
    let manager = LivePreviewManager(livePreviewService: LivePreviewService(), adbService: adb, options: options) { _ in }
    let start = Task { await manager.start(with: [first]) }
    await eventually { await gate.waitCount == 1 }
    let update = Task { await manager.updateDevices([first]) }
    for _ in 0 ..< 100 {
      await Task.yield()
    }
    let requests = await adb.displayRequests
    precondition(requests == [first.id], "Concurrent updates must share the pending query")
    await gate.open()
    await start.value
    await update.value
    await manager.updateDevices([first])
    let completedRequests = await adb.displayRequests
    precondition(completedRequests == [first.id], "Completed metadata must come from the value cache")
    await manager.stop()
  }

  static func stoppingEmulatorBeforeFirstFrame() async {
    let emulator = testDevice("emulator-5554")
    let service = LivePreviewService(readyGate: TestGate())
    var captures: [CaptureMedia] = []
    let manager = LivePreviewManager(livePreviewService: service, adbService: ADBService(), options: options) { captures = $0 }
    await manager.start(with: [emulator])
    await eventually { await service.active.count == 1 }
    await manager.stop()
    let active = await service.active
    precondition(active.isEmpty && captures.isEmpty)
  }

  static func emulatorReconnectDiscardsOldWarmup() async {
    let emulator = testDevice("emulator-5554")
    let gate = TestGate()
    let service = LivePreviewService(startGate: gate)
    let manager = LivePreviewManager(livePreviewService: service, adbService: ADBService(), options: options) { _ in }
    await manager.start(with: [emulator])
    await eventually { await service.starts.count == 1 }
    let disconnect = Task { await manager.updateDevices([]) }
    for _ in 0 ..< 20 {
      await Task.yield()
    }
    await manager.updateDevices([emulator])
    await eventually { await service.starts.count == 2 }
    await gate.open()
    await disconnect.value
    await manager.stop()
    await eventually { await service.stops.count == 2 }
    let active = await service.active
    precondition(active.isEmpty, "Both the stale and unclaimed replacement warmups must release their streams")
    await manager.stop()
  }

  static func rendererUsesLatestMediaAfterReadiness() async throws {
    let gate = TestGate()
    let service = LivePreviewService(readyGate: gate)
    var captures: [CaptureMedia] = []
    let manager = LivePreviewManager(livePreviewService: service, adbService: ADBService(), options: options) { captures = $0 }
    await manager.start(with: [first])
    let renderer = try await manager.makeRenderer(for: first.id)
    await eventually { await gate.waitCount == 1 }
    renderer.operation.session.media = .livePreview(
      capturedAt: Date(), display: DisplayInfo(size: testDisplay.size, densityScale: 4)
    )
    await gate.open()
    await eventually { captures.first?.media.densityScale == 4 }
    await manager.stop()
  }

  static func emulatorInputWaitsForAndroid() async throws {
    let emulator = testDevice("emulator-5554")
    let gate = TestGate()
    let adb = ADBService()
    let service = LivePreviewService(interactiveGate: gate)
    var visible = false
    let manager = LivePreviewManager(livePreviewService: service, adbService: adb, options: options) { visible = !$0.isEmpty }
    await manager.start(with: [emulator])
    await eventually { visible }
    let renderer = try await manager.makeRenderer(for: emulator.id)
    await eventually { await gate.waitCount == 1 }
    renderer.sendPointer(.down, .touchscreen, [.zero], testDisplay.size)
    for _ in 0 ..< 20 {
      await Task.yield()
    }
    let before = await adb.pointerEvents
    let preparedBefore = await adb.pointerPreparations
    precondition(before.isEmpty && preparedBefore.isEmpty)
    await gate.open()
    await eventually { await adb.pointerPreparations == [emulator.id] }
    renderer.sendPointer(.down, .touchscreen, [.zero], testDisplay.size)
    await eventually { await adb.pointerEvents.count == 1 }
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

  static func reconnectDuringPreparedReadiness() async {
    let service = LivePreviewService(readyGate: TestGate())
    var displayed: [String] = []
    let manager = LivePreviewManager(
      livePreviewService: service, adbService: ADBService(), options: options,
      preparedLivePreview: prepare(service)
    ) { displayed = $0.map(\.device.id) }
    await manager.start(with: [first])
    await eventually { await service.active.count == 1 }
    await manager.updateDevices([])
    await manager.updateDevices([first])
    await eventually { displayed == [first.id] }
    await manager.stop()
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
      AppSettings.shared.lastViewedDeviceID = nil
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
      await eventually { await readyGate.waitCount > 0 }
      await eventually { controller.isLivePreviewActive }
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

  static func restoresPreferredDevice() async {
    let fixture = ControllerFixture(devices: [first, second])
    AppSettings.shared.lastViewedDeviceID = second.id
    await fixture.displayGate.open()
    await fixture.readyGate.open()
    await fixture.stopGate.open()
    await fixture.controller.start()
    await eventually { fixture.controller.selectedDeviceID == second.id }
    let starts = await fixture.live.starts
    precondition(starts.first == second.id, "Startup must prewarm the previous device even when it is second in the list")
    await fixture.controller.tearDown()
    AppSettings.shared.lastViewedDeviceID = nil
  }

  static func waitsForPreferredDeviceMedia() async {
    let gate = TestGate()
    let service = LivePreviewService(readyGate: gate)
    let snapshots = CaptureSnapshotController()
    let mode = LivePreviewMode(
      livePreviewService: service, adbService: ADBService(), options: options,
      preparedLivePreview: prepare(service),
      mediaDisplayMode: MediaDisplayMode(snapshotController: snapshots),
      preferredDeviceIDProvider: { first.id }, onMediaApplied: {}
    )
    await mode.start(with: [first, second])
    precondition(snapshots.mediaList.map(\.device.id) == [second.id])
    precondition(snapshots.currentCapture == nil, "A faster sibling must not replace the selected device during startup")
    await gate.open()
    await eventually { snapshots.currentCapture?.device.id == first.id }
    await mode.updateDevices([second])
    precondition(snapshots.currentCapture?.device.id == second.id, "Disconnecting the preferred device must allow fallback")
    await mode.stop()
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
    await fixture.stopGate.open()
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
