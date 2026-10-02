import AppKit
import Clocks
import ConcurrencyExtras
import Dependencies
import Foundation

@main
@MainActor
struct StartupCaptureTests {
  static let options = LivePreviewOptions(showsTouches: false)
  static let first = testDevice("first")
  static let second = testDevice("second")

  static func main() async throws {
    try await withMainSerialExecutor {
      try await withDependencies {
        $0.context = .test
        $0.continuousClock = TestClock()
      } operation: {
        try await CaptureModeTests.run()
        try copyUsesSelectedCaptureCrop()
        await screenshotReuse()
        await screenshotFreshness()
        await livePreviewClaim()
        try await startupExpirationPreservesDependencies()
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
        try await deviceNameUpdatesPreservePreview()
        await emulatorWarmupPreservesMatchingPreparedStream()
        try await managerRetriesBootingDevice(densityUnavailable: false)
        try await managerRetriesBootingDevice(densityUnavailable: true)
        await displayRetryCancellation(stops: false)
        await displayRetryCancellation(stops: true)
        try await deviceArrivalAfterWindowOpens()
        await discoveryWaitsForBootComplete()
        await discoveryBacksOffStalledDevice()
        await stopDuringRendererClaim()
        await disconnectWaitsForCleanup()
        await reconnectDuringPreparedReadiness()
        for startupMode in [StartupCaptureMode.screenshot, .livePreview] {
          for command in [SnapOCommand.record, .capture, .livepreview, nil] {
            await startupUsesRequestedMode(command, startupMode: startupMode, remounts: false)
            await startupUsesRequestedMode(command, startupMode: startupMode, remounts: true)
          }
        }
        await commandDuringAutomaticPreview(recordsVideo: true)
        await commandDuringAutomaticPreview(recordsVideo: false)
        await tearDownDuringQueuedCommand(recordsVideo: true)
        await tearDownDuringQueuedCommand(recordsVideo: false)
        await disconnectDuringQueuedCommand()
        await commandAfterPreparedPreviewReady()
        await captureReviewAllowsReplacement { await $0.startRecording() }
        await captureReviewAllowsReplacement { await $0.startLivePreview() }
        await captureReviewAllowsReplacement { await $0.captureScreenshots() }
        await cancelledQueuedCommand()
        await commandDuringAutomaticPreview(recordsVideo: true, previewReadyFirst: true)
        await commandDuringAutomaticPreview(recordsVideo: false, previewReadyFirst: true)
        await captureHistoryDeletion(deletesCurrent: true)
        await captureHistoryDeletion(deletesCurrent: false)
        await captureHistoryDeletion(deletesCurrent: true, deletesAll: true)
        await captureHistoryDeletion(deletesCurrent: true, disconnects: true)
        await captureHistoryDeletion(deletesCurrent: true, managed: false)
        await deviceManagerOpenPreservesLaterSelection()
        await opensBootingEmulatorWithScreenshotStartup()
        await switchBetweenBootingAndReadyDevices()
        await rapidSelectionKeepsLatestDevice()
        await manualSelectionReplacesPendingOpen { $0.selectMedia(id: $0.mediaList.first!.id) }
        await manualSelectionReplacesPendingOpen { $0.selectNextMedia() }
        await manualSelectionReplacesPendingOpen { $0.selectPreviousMedia() }
        await selectedDeviceSurvivesDisconnect()
        await cancelledOpenDoesNotRestoreItsSelection(cancelTask: true)
        await cancelledOpenDoesNotRestoreItsSelection(cancelTask: false)
        await restoresPreferredDevice()
        await waitsForPreferredDeviceMedia()
        await stopReleasesWindowLevel()
        await stopShowsRecordings()
        print("Startup capture tests passed")
      }
    }
  }

  static func eventually(
    _ message: String = "Condition did not become true", file: StaticString = #file, line: UInt = #line,
    _ condition: @escaping @MainActor @Sendable () -> Bool
  ) async {
    await waitForObservedTestState(condition, message: message, file: file, line: line)
  }

  static func eventually(
    _ message: String = "Condition did not become true", file: StaticString = #file, line: UInt = #line,
    _ condition: () async -> Bool
  ) async {
    await waitForActorTestState(condition, message: message, file: file, line: line)
  }

  static func prepare(
    _ service: LivePreviewService,
    device: Device = first
  ) -> PreparedLivePreview {
    PreparedLivePreview(
      deviceID: device.id,
      options: options,
      operationTask: Task { try? await service.start(for: device.id, options: options) },
      service: service
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

  static func startupExpirationPreservesDependencies() async throws {
    for startsEarly in [true, false] {
      let clock = TestClock()
      try await withDependencies { $0.continuousClock = clock } operation: {
        let service = LivePreviewService()
        let startup = StartupCapturePreparation(screenshots: ScreenshotService(), livePreview: service)
        if startsEarly {
          startup.prepareEarlyPreview(options: options) { [id = first.id] in
            @Dependency(\.continuousClock)
            var inheritedClock
            precondition(inheritedClock as? TestClock<Duration> === clock, "Early discovery must inherit the test clock")
            return id
          }
        } else {
          startup.prepare(mode: .livePreview, devices: [first], liveOptions: options)
        }
        guard let prepared = await startup.claimLivePreview(for: first, options: options) else {
          fatalError("Missing startup preview")
        }
        await eventually { await service.active.count == 1 }
        await clock.advance(by: .seconds(4))
        precondition(prepared.isAvailable, "Warmup must remain available before its deadline")
        await clock.advance(by: .seconds(1))
        await eventually { await service.stops.count == 1 }
        precondition(!prepared.isAvailable, "Startup warmup must expire on the inherited clock")
        await prepared.discard()
        try await clock.checkSuspension()
      }
    }
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
    let clock = TestClock()
    await withDependencies { $0.continuousClock = clock } operation: {
      let service = LivePreviewService()
      let prepared = prepare(service)
      await eventually { await service.active.count == 1 }
      precondition(prepared.isAvailable)
      await clock.advance(by: .seconds(5))
      await eventually { await service.stops.count == 1 }
      precondition(!prepared.isAvailable)
      let handle = await prepared.take()
      let active = await service.active
      let stops = await service.stops
      precondition(handle == nil && active.isEmpty && stops.count == 1)
    }
  }

  static func cancelledClaimCleansUp() async {
    let gate = TestGate()
    let service = LivePreviewService(startGate: gate)
    let prepared = prepare(service)
    let take = await startTestTask { await prepared.take() }
    precondition(!prepared.isAvailable)
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

    let secondDiscardFinished = TestValue(false)
    let secondDiscard = await startTestTask {
      await prepared.discard()
      secondDiscardFinished.value = true
    }
    let takeFinished = TestValue(false)
    let take = await startTestTask {
      let result = await prepared.take()
      takeFinished.value = true
      return result
    }

    await readyGate.open()
    let media = await readiness.value
    precondition(media == nil && !prepared.isAvailable)
    precondition(!secondDiscardFinished.value && !takeFinished.value)

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
    let displayed = TestValue<[String]>([])
    let manager = LivePreviewManager(
      livePreviewService: service,
      adbService: ADBService(displayGates: [second.id: slowDisplay]),
      options: options,
      preparedLivePreview: prepared
    ) { displayed.value = $0.map(\.device.id) }
    let start = Task { await manager.start(with: [first, second]) }
    await eventually { displayed.value.contains(first.id) }
    precondition(!displayed.value.contains(second.id))
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
    let visible = TestValue(0)
    let manager = LivePreviewManager(
      livePreviewService: service, adbService: ADBService(), options: options,
      preparedLivePreview: prepare(service, device: devices[1])
    ) { visible.value = $0.count }
    await manager.start(with: devices)
    await eventually { visible.value == 2 }
    let starts = await service.starts
    precondition(starts.count(where: { $0 == devices[1].id }) == 1, "The matching warmup must reuse the prepared stream")
    let renderer = try! await manager.makeRenderer(for: devices[1].id)
    let afterClaim = await service.starts
    precondition(afterClaim == starts, "Renderer must retain the warmed stream without reopening it")
    await manager.stopRenderer(renderer)
    await manager.stop()
  }

  static func managerRetriesBootingDevice(densityUnavailable: Bool) async throws {
    let clock = TestClock()
    try await withDependencies { $0.continuousClock = clock } operation: {
      let adb = ADBService(
        displayFailures: densityUnavailable ? [:] : [first.id: 2],
        densityFailures: densityUnavailable ? [first.id: 2] : [:]
      )
      let service = LivePreviewService()
      let failedWarmup = PreparedLivePreview(
        deviceID: first.id, options: options, operationTask: Task { nil }, service: service
      )
      let displayed = TestValue<[String]>([])
      let manager = LivePreviewManager(
        livePreviewService: service, adbService: adb, options: options,
        preparedLivePreview: failedWarmup
      ) { displayed.value = $0.map(\.device.id) }
      await manager.start(with: [first, second])
      await eventually("A booting device must not block a ready device") { displayed.value == [second.id] }
      for (index, delay) in [1, 2].enumerated() {
        await clock.advance(by: .seconds(delay))
        await eventually { await adb.displayRequests.count { $0 == first.id } == index + 2 }
      }
      await eventually("Retry must create media without another device update") { displayed.value == [first.id, second.id] }
      let requests = await adb.displayRequests
      precondition(requests.count(where: { $0 == first.id }) == 3)
      precondition(requests.count(where: { $0 == second.id }) == 1, "Ready devices must not be queried again")
      let renderer = try await manager.makeRenderer(for: first.id)
      await eventually { renderer.operation.session.isReady }
      let starts = await service.starts
      precondition(starts == [first.id], "A failed warmup must allow a fresh preview stream")
      await manager.stop()
    }
  }

  static func discoveryWaitsForBootComplete() async {
    let clock = TestClock()
    await withDependencies { $0.continuousClock = clock } operation: {
      let adb = ADBService()
      await adb.setBooting(true, deviceID: first.id)
      let displayed = TestValue<[String]>([])
      let manager = LivePreviewManager(
        livePreviewService: LivePreviewService(), adbService: adb, options: options,
        mediaDidChange: { displayed.value = $0.map(\.device.id) }
      )
      await manager.start(with: [first, second])
      precondition(displayed.value == [second.id])
      let requestsBeforeBoot = await adb.displayRequests
      precondition(requestsBeforeBoot == [second.id], "Booting devices must not receive display queries")
      await adb.setBooting(false, deviceID: first.id)
      await clock.advance(by: .seconds(1))
      await eventually { displayed.value == [first.id, second.id] }
      await manager.stop()
    }
  }

  static func discoveryBacksOffStalledDevice() async {
    let clock = TestClock()
    await withDependencies { $0.continuousClock = clock } operation: {
      let adb = ADBService(displayFailures: [first.id: 7])
      let displayed = TestValue<[String]>([])
      let manager = LivePreviewManager(
        livePreviewService: LivePreviewService(), adbService: adb, options: options,
        mediaDidChange: { displayed.value = $0.map(\.device.id) }
      )
      await manager.start(with: [first, second])
      for (index, seconds) in [1, 2, 4, 8, 10, 10, 10].enumerated() {
        await clock.advance(by: .seconds(seconds) - .milliseconds(1))
        let beforeRetry = await adb.displayRequests.count { $0 == first.id }
        precondition(beforeRetry == index + 1, "Do not retry before the backoff deadline")
        await clock.advance(by: .milliseconds(1))
        await eventually { await adb.displayRequests.count { $0 == first.id } == index + 2 }
      }
      await eventually { displayed.value == [first.id, second.id] }
      let requests = await adb.displayRequests
      precondition(requests.count { $0 == second.id } == 1, "Healthy devices must not be rediscovered while another retries")
      await manager.stop()
    }
  }

  static func deviceArrivalAfterWindowOpens() async throws {
    AppSettings.shared.startupCaptureMode = .livePreview
    let tracker = DeviceManager(devices: [])
    let live = LivePreviewService()
    let screenshots = ScreenshotService()
    let controller = CaptureWindowController(
      captureServices: CaptureServices(
        screenshots: screenshots, recording: RecordingService(), livePreview: live,
        startup: StartupCapturePreparation(screenshots: screenshots, livePreview: live)
      ),
      deviceManager: tracker, fileStore: FileStore(),
      adbService: ADBService()
    )
    await controller.start()
    await eventually { controller.isDeviceListInitialized }
    precondition(!controller.hasDevices && controller.currentCapture == nil)
    tracker.updateDevices([first])
    await eventually { controller.isLivePreviewActive }
    await eventually { controller.currentCapture != nil }
    precondition(controller.currentCapture?.device.id == first.id, "A device arriving after startup must receive a preview")
    precondition(!controller.isProcessing)
    guard let renderer = await controller.startLivePreviewStream(for: first.id) else {
      fatalError("The connected device must provide a preview renderer")
    }
    await eventually { renderer.operation.session.isReady }
    await controller.tearDown()
    let active = await live.active
    precondition(active.isEmpty)
  }

  static func displayRetryCancellation(stops: Bool) async {
    let clock = TestClock()
    await withDependencies { $0.continuousClock = clock } operation: {
      let queryGate = TestGate()
      let adb = ADBService(displayFailures: [first.id: 1])
      let displayed = TestValue<[String]>([])
      let manager = LivePreviewManager(
        livePreviewService: LivePreviewService(), adbService: adb, options: options,
        mediaDidChange: { displayed.value = $0.map(\.device.id) }
      )
      await manager.start(with: [first])
      await adb.setDisplayGate(queryGate, for: first.id)
      await clock.advance(by: .seconds(1))
      await eventually { await queryGate.waitCount == 1 }
      let retry = manager.displayRetryTask
      if stops {
        await manager.stop()
      } else {
        await manager.updateDevices([])
      }
      await queryGate.open()
      await retry?.value
      precondition(displayed.value.isEmpty, "A late display response must not restore a disconnected or stopped preview")
      let requests = await adb.displayRequests
      precondition(requests.count == 2, "Canceled discovery must not schedule more queries")
      await manager.stop()
    }
  }

  static func emulatorFramesCreatePreviewBeforeBoot() async throws {
    let emulator = testDevice("emulator-5554")
    let adb = ADBService()
    await adb.setBooting(true, deviceID: emulator.id)
    let service = LivePreviewService()
    let captures = TestValue<[CaptureMedia]>([])
    let manager = LivePreviewManager(livePreviewService: service, adbService: adb, options: options) { captures.value = $0 }
    await manager.start(with: [emulator])
    await eventually { captures.value.count == 1 }
    precondition(captures.value[0].media.size == testDisplay.size)
    let requests = await adb.displayRequests
    precondition(requests.isEmpty, "First-frame sizing must not require Android display services")
    await manager.stop()
  }

  static func unusedEmulatorWarmupReleasesStream() async throws {
    try await withDependencies {
      $0 = DependencyValues()
      $0.context = .test
    } operation: {
      let clock = TestClock()
      let emulator = testDevice("emulator-5554")
      let service = LivePreviewService()
      let visible = TestValue(false)
      let manager = withDependencies { $0.continuousClock = clock } operation: {
        LivePreviewManager(
          livePreviewService: service,
          adbService: ADBService(),
          options: options
        ) { visible.value = !$0.isEmpty }
      }
      // A warmup created later must inherit its manager's clock.
      await manager.start(with: [emulator])
      await eventually { visible.value }
      let retained = await service.active
      precondition(retained.count == 1, "Warmup must remain available for renderer handoff")
      await clock.advance(by: .seconds(5))
      await eventually { await service.active.isEmpty }
      let active = await service.active
      precondition(active.isEmpty, "Unused warmups must expire")
      let renderer = try await manager.makeRenderer(for: emulator.id)
      let starts = await service.starts
      precondition(starts == [emulator.id, emulator.id], "An expired warmup must allow a fresh renderer")
      await manager.stopRenderer(renderer)
      await manager.stop()
    }
  }

  static func claimEmulatorBeforeFirstFrame() async throws {
    let clock = TestClock()
    try await withDependencies { $0.continuousClock = clock } operation: {
      let emulator = testDevice("emulator-5554")
      let gate = TestGate()
      let service = LivePreviewService(readyGate: gate)
      let manager = LivePreviewManager(
        livePreviewService: service, adbService: ADBService(), options: options
      ) { _ in }
      await manager.start(with: [emulator])
      await eventually { await gate.waitCount > 0 }
      await clock.advance(by: .seconds(5))
      let active = await service.active
      precondition(active.count == 1, "An unready warmup must not expire")
      let renderer = try await manager.makeRenderer(for: emulator.id)
      precondition(!renderer.operation.session.isReady)
      await gate.open()
      await eventually { renderer.operation.session.isReady }
      let starts = await service.starts
      precondition(starts == [emulator.id], "Claiming an unfinished warmup must retain its operation")
      await manager.stopRenderer(renderer)
      await manager.stop()
    }
  }

  static func overlappingDisplayDiscovery() async {
    let gate = TestGate()
    let adb = ADBService(displayGates: [first.id: gate])
    let manager = LivePreviewManager(livePreviewService: LivePreviewService(), adbService: adb, options: options) { _ in }
    let start = Task { await manager.start(with: [first]) }
    await eventually { await gate.waitCount == 1 }
    let update = await startTestTask { await manager.updateDevices([first]) }
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
    let captures = TestValue<[CaptureMedia]>([])
    let manager = LivePreviewManager(livePreviewService: service, adbService: ADBService(), options: options) { captures.value = $0 }
    await manager.start(with: [emulator])
    await eventually { await service.active.count == 1 }
    await manager.stop()
    let active = await service.active
    precondition(active.isEmpty && captures.value.isEmpty)
  }

  static func emulatorReconnectDiscardsOldWarmup() async {
    let emulator = testDevice("emulator-5554")
    let gate = TestGate()
    let service = LivePreviewService(startGate: gate)
    let manager = LivePreviewManager(livePreviewService: service, adbService: ADBService(), options: options) { _ in }
    await manager.start(with: [emulator])
    await eventually { await service.starts.count == 1 }
    let disconnect = await startTestTask { await manager.updateDevices([]) }
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
    let captures = TestValue<[CaptureMedia]>([])
    let manager = LivePreviewManager(livePreviewService: service, adbService: ADBService(), options: options) { captures.value = $0 }
    await manager.start(with: [first])
    let renderer = try await manager.makeRenderer(for: first.id)
    await eventually { await gate.waitCount == 1 }
    renderer.operation.session.media = .livePreview(
      capturedAt: Date(), display: DisplayInfo(size: testDisplay.size, densityScale: 4)
    )
    await gate.open()
    await eventually { captures.value.first?.media.densityScale == 4 }
    await manager.stop()
  }

  static func deviceNameUpdatesPreservePreview() async throws {
    AppSettings.shared.startupCaptureMode = .livePreview
    let devices = DeviceManager(devices: [first])
    let service = LivePreviewService()
    let screenshots = ScreenshotService()
    let controller = CaptureWindowController(
      captureServices: CaptureServices(
        screenshots: screenshots, recording: RecordingService(), livePreview: service,
        startup: StartupCapturePreparation(screenshots: screenshots, livePreview: service)
      ),
      deviceManager: devices, fileStore: FileStore(), adbService: ADBService()
    )
    await controller.start()
    await eventually { controller.currentCapture != nil }
    guard let renderer = await controller.startLivePreviewStream(for: first.id) else {
      fatalError("Expected live preview renderer")
    }
    let capture = controller.currentCapture!
    let viewID = controller.snapshotController.currentCaptureViewID
    let starts = await service.starts
    let renamed = Device(
      id: first.id, model: first.model, androidVersion: first.androidVersion,
      vendorModel: first.vendorModel, manufacturer: first.manufacturer, avdName: first.avdName,
      displayName: "Renamed device"
    )
    devices.updateDevices([renamed])
    await eventually { controller.currentCaptureDeviceTitle == "Renamed device" }
    precondition(controller.currentCapture?.id == capture.id)
    precondition(controller.snapshotController.currentCaptureViewID == viewID)
    let updatedStarts = await service.starts
    precondition(updatedStarts == starts, "A name update must not restart the preview")
    precondition(capture.device == first, "Previously captured device values must not change")
    await controller.stopLivePreviewStream(renderer)
    await controller.tearDown()
  }

  static func emulatorInputWaitsForAndroid() async throws {
    let emulator = testDevice("emulator-5554")
    let gate = TestGate()
    let adb = ADBService()
    let service = LivePreviewService(interactiveGate: gate)
    let visible = TestValue(false)
    let manager = LivePreviewManager(livePreviewService: service, adbService: adb, options: options) { visible.value = !$0.isEmpty }
    await manager.start(with: [emulator])
    await eventually { visible.value }
    let renderer = try await manager.makeRenderer(for: emulator.id)
    await eventually { await gate.waitCount == 1 }
    await CaptureModeTests.click(manager, renderer)
    let before = await adb.pointerEvents
    let preparedBefore = await adb.pointerPreparations
    precondition(before.isEmpty && preparedBefore.isEmpty)
    await gate.open()
    await manager.waitUntilInteractive(renderer)
    await CaptureModeTests.click(manager, renderer)
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
    let disconnect = await startTestTask { await manager.updateDevices([]) }
    await eventually { await service.stops.count == 1 }
    let stopped = TestValue(false)
    let stop = await startTestTask { await manager.stop()
      stopped.value = true
    }
    precondition(!stopped.value)
    await stopGate.open()
    await disconnect.value
    await stop.value
    let active = await service.active
    precondition(stopped.value && active.isEmpty)
  }

  static func reconnectDuringPreparedReadiness() async {
    let service = LivePreviewService(readyGate: TestGate())
    let displayed = TestValue<[String]>([])
    let manager = LivePreviewManager(
      livePreviewService: service, adbService: ADBService(), options: options,
      preparedLivePreview: prepare(service)
    ) { displayed.value = $0.map(\.device.id) }
    await manager.start(with: [first])
    await eventually { await service.active.count == 1 }
    await manager.updateDevices([])
    await manager.updateDevices([first])
    await eventually { displayed.value == [first.id] }
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
    let renderer = await startTestTask { try? await manager.makeRenderer(for: first.id) }
    precondition(!prepared.isAvailable)
    let stopped = TestValue(false)
    let stop = await startTestTask { await manager.stop()
      stopped.value = true
    }
    precondition(!stopped.value)
    await gate.open()
    let result = await renderer.value
    await stop.value
    let active = await service.active
    precondition(result == nil && stopped.value && active.isEmpty)
  }

  @MainActor
  struct ControllerFixture {
    let displayGate = TestGate()
    let readyGate = TestGate()
    let stopGate = TestGate()
    let screenshots = ScreenshotService()
    let recording = RecordingService()
    let tracker: DeviceManager
    let live: LivePreviewService
    let controller: CaptureWindowController

    init(devices: [Device] = [first], blockedDisplayDevice: Device = first) {
      AppSettings.shared.lastViewedDeviceID = nil
      AppSettings.shared.startupCaptureMode = .livePreview
      tracker = DeviceManager(devices: devices)
      live = LivePreviewService(stopGate: stopGate, readyGate: readyGate)
      controller = CaptureWindowController(
        captureServices: CaptureServices(
          screenshots: screenshots,
          recording: recording,
          livePreview: live,
          startup: StartupCapturePreparation(screenshots: screenshots, livePreview: live)
        ),
        deviceManager: tracker,
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
      let didStart = TestValue(false)
      let task = Task {
        didStart.value = true
        if recordsVideo {
          await controller.startRecording()
        } else {
          await controller.captureScreenshots()
        }
      }
      await eventually { didStart.value }
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
    let startsBeforeOpen = await fixture.live.starts
    let stopsBeforeOpen = await fixture.live.stops
    await controller.showLivePreview(deviceID: second.id)
    await controller.showLivePreview(deviceID: second.id)
    await eventually { controller.selectedDeviceID == second.id }
    let startsAfterOpen = await fixture.live.starts
    let stopsAfterOpen = await fixture.live.stops
    precondition(startsAfterOpen == startsBeforeOpen, "Opening a device must reuse its active preview")
    precondition(stopsAfterOpen == stopsBeforeOpen, "Repeated opens must not stop active previews")
    controller.selectMedia(id: firstMediaID)
    await eventually { controller.selectedDeviceID == first.id }

    let third = testDevice("third")
    fixture.tracker.updateDevices([first, second, third])
    await eventually { controller.mediaList.count == 3 }
    precondition(controller.selectedDeviceID == first.id, "Device Manager must not override a later selection")
    await controller.tearDown()
  }

  static func opensBootingEmulatorWithScreenshotStartup() async {
    let emulator = testDevice("emulator-5554")
    let fixture = ControllerFixture(devices: [])
    AppSettings.shared.startupCaptureMode = .screenshot
    await fixture.displayGate.open()
    await fixture.readyGate.open()
    await fixture.stopGate.open()
    await fixture.controller.start()
    await eventually { fixture.controller.isDeviceListInitialized }
    fixture.tracker.updatePreviewDevices([emulator])

    await fixture.controller.showLivePreview(deviceID: emulator.id)
    await eventually { fixture.controller.currentCapture?.device.id == emulator.id }
    precondition(fixture.controller.isLivePreviewActive)
    precondition(fixture.tracker.latestDevices.isEmpty, "Preview must open before Android reports boot completion")
    await fixture.assertNoCaptureRequests()
    await fixture.controller.tearDown()
  }

  static func switchBetweenBootingAndReadyDevices() async {
    let booting = testDevice("emulator-5554")
    let fixture = ControllerFixture(devices: [booting, second], blockedDisplayDevice: booting)
    await fixture.stopGate.open()
    let controller = fixture.controller
    await controller.start()
    await eventually { controller.mediaList.map(\.device.id) == [second.id] }
    precondition(controller.currentCapture == nil, "The booting device is selected before its first frame")

    await controller.showLivePreview(deviceID: second.id)
    await eventually { controller.currentCapture?.device.id == second.id }
    await controller.showLivePreview(deviceID: booting.id)
    precondition(controller.currentCapture == nil, "Selecting a booting device must show its loading view")
    precondition(controller.loadingPreviewDeviceID == booting.id)
    await controller.showLivePreview(deviceID: second.id)
    await eventually { controller.currentCapture?.device.id == second.id }

    await fixture.readyGate.open()
    await fixture.displayGate.open()
    await eventually { controller.mediaList.count == 2 }
    precondition(controller.currentCapture?.device.id == second.id, "A late preview must not replace the chosen device")
    await controller.showLivePreview(deviceID: booting.id)
    await eventually { controller.currentCapture?.device.id == booting.id }
    await controller.tearDown()
  }

  static func rapidSelectionKeepsLatestDevice() async {
    let booting = testDevice("emulator-5554")
    let fixture = ControllerFixture(devices: [booting, second], blockedDisplayDevice: booting)
    await fixture.stopGate.open()
    let controller = fixture.controller
    await controller.start()
    await eventually { controller.mediaList.map(\.device.id) == [second.id] }

    controller.selectDevice(id: second.id)
    precondition(controller.currentCapture?.device.id == second.id, "A device choice must take effect immediately")
    controller.selectDevice(id: booting.id)
    precondition(controller.currentCapture == nil, "The newer choice must wait for its own preview")
    await fixture.readyGate.open()
    await fixture.displayGate.open()
    await eventually { controller.mediaList.count == 2 }
    precondition(controller.currentCapture?.device.id == booting.id, "An older choice must not replace the latest device")
    await controller.tearDown()
  }

  static func manualSelectionReplacesPendingOpen(_ select: (CaptureWindowController) -> Void) async {
    let fixture = ControllerFixture(devices: [first, second])
    await fixture.displayGate.open()
    await fixture.readyGate.open()
    await fixture.stopGate.open()
    let controller = fixture.controller
    await controller.start()
    await eventually { controller.mediaList.count == 2 && !controller.isProcessing }
    let booting = testDevice("emulator-5554")
    controller.deviceOpenRequest = .serial(booting.id)
    controller.selectDevice(id: booting.id)
    precondition(controller.currentCapture == nil)

    select(controller)
    let selectedID = controller.currentCapture?.device.id
    precondition(selectedID == first.id)
    precondition(controller.deviceOpenRequest == nil, "Manual selection must cancel the older request")
    precondition(controller.loadingPreviewDeviceID == selectedID)
    fixture.tracker.updateDevices([first, second, booting])
    await eventually { controller.mediaList.count == 3 }
    precondition(controller.currentCapture?.device.id == selectedID, "Late readiness must not undo manual selection")
    await controller.tearDown()
  }

  static func selectedDeviceSurvivesDisconnect() async {
    let fixture = ControllerFixture(devices: [first, second])
    await fixture.displayGate.open()
    await fixture.readyGate.open()
    await fixture.stopGate.open()
    let controller = fixture.controller
    await controller.start()
    await eventually { controller.mediaList.count == 2 && !controller.isProcessing }
    await controller.showLivePreview(deviceID: second.id)
    await eventually { controller.currentCapture?.device.id == second.id }

    fixture.tracker.updateDevices([first])
    await eventually { controller.mediaList.map(\.device.id) == [first.id] }
    precondition(controller.currentCapture == nil, "A disconnect must not select another available device")
    precondition(controller.loadingPreviewDeviceID == second.id)
    let third = testDevice("third")
    fixture.tracker.updateDevices([first, third])
    await eventually { controller.mediaList.count == 2 }
    precondition(controller.currentCapture == nil, "A newly connected device must not replace the user's choice")
    precondition(controller.loadingPreviewDeviceID == second.id)
    fixture.tracker.updateDevices([first, third, second])
    await eventually { controller.currentCapture?.device.id == second.id }
    await controller.tearDown()
  }

  static func cancelledOpenDoesNotRestoreItsSelection(cancelTask: Bool) async {
    let readyEmulator = testDevice("emulator-5556")
    let fixture = ControllerFixture(devices: [])
    AppSettings.shared.startupCaptureMode = .screenshot
    await fixture.stopGate.open()
    await fixture.readyGate.open()
    let controller = fixture.controller
    await controller.start()
    await eventually { controller.isDeviceListInitialized }
    fixture.tracker.updatePreviewDevices([first, readyEmulator])
    controller.deviceOpenRequest = .serial(first.id)
    let opening = Task { await controller.showLivePreview(deviceID: first.id) }
    await eventually { controller.isLivePreviewActive }
    await eventually { controller.mediaList.contains { $0.device.id == readyEmulator.id } }
    if cancelTask { opening.cancel() }
    controller.deviceOpenRequest = .serial(readyEmulator.id)
    await controller.showLivePreview(deviceID: readyEmulator.id)
    await eventually { controller.currentCapture?.device.id == readyEmulator.id }
    await fixture.displayGate.open()
    await opening.value
    precondition(controller.loadingPreviewDeviceID == readyEmulator.id, "A cancelled open must not select its original target")
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
    precondition(snapshots.currentCapture == nil, "Keep waiting for the selected device after a disconnect")
    await mode.updateDevices([first, second])
    await eventually { snapshots.currentCapture?.device.id == first.id }
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
      fixture.tracker.updateDevices([])
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

  static func startupUsesRequestedMode(
    _ command: SnapOCommand?, startupMode: StartupCaptureMode, remounts: Bool
  ) async {
    let fixture = ControllerFixture(devices: [])
    AppSettings.shared.startupCaptureMode = startupMode
    AppSettings.shared.recordAsBugReport = false
    if let command { await fixture.controller.perform(command) }
    await fixture.controller.start()
    if remounts {
      await fixture.controller.tearDown()
      await fixture.controller.start()
    }
    await fixture.assertNoCaptureRequests()
    await fixture.readyGate.open()
    await fixture.displayGate.open()
    await fixture.stopGate.open()
    // Repeated discovery must not start the default alongside a queued command.
    fixture.tracker.updateDevices([first])
    fixture.tracker.updateDevices([first])

    await eventually {
      fixture.controller.isReviewingCapture || fixture.controller.isRecording
        || (fixture.controller.isLivePreviewActive && !fixture.controller.isProcessing)
    }
    let expected = command ?? (startupMode == .screenshot ? .capture : .livepreview)
    let matchesRequest = switch expected {
    case .capture: fixture.controller.isReviewingCapture
    case .record: fixture.controller.isRecording
    case .livepreview: fixture.controller.isLivePreviewActive
    }
    precondition(matchesRequest, "The URL command must take priority over the startup setting")
    let captures = await fixture.screenshots.requests
    precondition(captures == (expected == .capture ? [[first.id]] : []))
    let previews = await fixture.live.starts
    precondition(expected != .capture || previews.isEmpty)
    await fixture.controller.tearDown()
  }

  static func commandDuringAutomaticPreview(recordsVideo: Bool, previewReadyFirst: Bool = false) async {
    let fixture = ControllerFixture(devices: [first, second], blockedDisplayDevice: second)
    await fixture.start()
    let command = await fixture.request(recordsVideo: recordsVideo)
    if !recordsVideo { await fixture.assertNoCaptureRequests() }

    if previewReadyFirst {
      await fixture.readyGate.open()
    } else {
      await fixture.displayGate.open()
    }
    if !recordsVideo {
      await eventually("A screenshot must stop the automatic preview") { await fixture.live.stops.count == 1 }
      await fixture.assertNoCaptureRequests()
    }
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
    precondition(recordsVideo ? !active.isEmpty : active.isEmpty)
    if recordsVideo {
      precondition(fixture.controller.isLivePreviewActive, "Recording must keep preview interactive")
      let stops = await fixture.live.stops
      precondition(stops.isEmpty, "Recording must reuse the startup preview")
    }
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
    if !recordsVideo { await fixture.assertNoCaptureRequests() }
    precondition(!fixture.controller.isRecording && !fixture.controller.isLivePreviewActive)
  }

  static func disconnectDuringQueuedCommand() async {
    let fixture = ControllerFixture()
    await fixture.start()
    let command = await fixture.request(recordsVideo: true)
    fixture.tracker.updateDevices([])
    await eventually { !fixture.controller.hasDevices }
    await fixture.stopGate.open()
    await fixture.displayGate.open()
    await command.value
    let requests = await fixture.recording.requests
    precondition(requests.count <= 1, "Disconnection must not start another recording")
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

  static func stopReleasesWindowLevel() async {
    let fixture = ControllerFixture()
    AppSettings.shared.startupCaptureMode = .screenshot
    await fixture.displayGate.open()
    await fixture.controller.start()
    await eventually { fixture.controller.isReviewingCapture && fixture.controller.canStartRecordingNow }
    await fixture.readyGate.open()
    await fixture.stopGate.open()
    await fixture.controller.startRecording()
    await eventually { fixture.controller.isRecording && fixture.controller.isLivePreviewActive }
    precondition(!fixture.controller.shouldFloatRecordingWindow, "Interactive recording must keep normal window behavior")
    let finishGate = TestGate()
    await fixture.recording.blockFinish(on: finishGate)
    let stop = Task { await fixture.controller.stopRecording() }
    await eventually { await finishGate.waitCount > 0 }
    precondition(fixture.controller.isProcessing && fixture.controller.isRecording && fixture.controller.isFinishingRecording)
    precondition(!fixture.controller.shouldFloatRecordingWindow, "Stop must release the window before device work finishes")
    await finishGate.open()
    await stop.value
    precondition(!fixture.controller.isRecording && fixture.controller.isLivePreviewActive)
    await fixture.controller.tearDown()
  }

  static func copyUsesSelectedCaptureCrop() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).png")
    defer { try? FileManager.default.removeItem(at: url) }
    let bitmap = NSBitmapImageRep(
      bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 4, bitsPerSample: 8,
      samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    memset(bitmap.bitmapData, 255, bitmap.bytesPerRow * bitmap.pixelsHigh)
    try bitmap.representation(using: .png, properties: [:])!.write(to: url)
    let capture = CaptureMedia(
      device: first,
      media: .image(url: url, capturedAt: Date(), display: DisplayInfo(size: CGSize(width: 8, height: 4), densityScale: 1))
    )
    let fixture = ControllerFixture()
    fixture.controller.mediaDisplayMode.updateMediaList([capture], preserveDeviceID: nil, shouldSort: false)
    let pasteboard = NSPasteboard(name: .init("crop-copy-\(UUID().uuidString)"))
    defer { pasteboard.releaseGlobally() }
    fixture.controller.reviewCrops[capture.id] = CGRect(x: 0.5, y: 0, width: 0.5, height: 1)
    fixture.controller.copyCurrentImage(to: pasteboard)
    let cropped = NSImage(pasteboard: pasteboard)!.cgImage(forProposedRect: nil, context: nil, hints: nil)!
    precondition(cropped.width == 4 && cropped.height == 4)
  }

  static func captureReviewAllowsReplacement(_ startCapture: @MainActor (CaptureWindowController) async -> Void) async {
    let fixture = ControllerFixture()
    AppSettings.shared.startupCaptureMode = .screenshot
    await fixture.displayGate.open()
    await fixture.readyGate.open()
    await fixture.stopGate.open()
    let controller = fixture.controller
    await controller.start()
    await eventually { controller.isReviewingCapture && !controller.isProcessing }
    let ids = controller.mediaList.map(\.id)
    controller.reviewCrops[ids[0]] = CGRect(x: 0, y: 0, width: 0.5, height: 1)

    controller.isSavingReview = true
    await startCapture(controller)
    precondition(controller.mediaList.map(\.id) == ids, "A save in progress must keep its captures")
    precondition(controller.fileStore.discardedCaptureIDs.isEmpty)

    controller.isSavingReview = false
    await startCapture(controller)
    await eventually {
      !controller.isProcessing && (controller.isRecording || controller.isLivePreviewActive || controller.isReviewingCapture)
    }
    precondition(Set(controller.mediaList.map(\.id)).isDisjoint(with: ids), "New captures must replace unsaved captures")
    precondition(controller.fileStore.discardedCaptureIDs == [ids], "Replacing captures must clean up their temporary files")
    precondition(controller.reviewCrops.isEmpty)
    await controller.tearDown()
  }

  static func stopShowsRecordings() async {
    let fixture = ControllerFixture(devices: [first, second])
    await fixture.displayGate.open()
    await fixture.readyGate.open()
    await fixture.controller.start()
    await eventually { fixture.controller.mediaList.count == 2 && !fixture.controller.isProcessing }
    let media = [first, second].map { device in
      CaptureMedia(device: device, media: .video(
        url: URL(fileURLWithPath: "/tmp/recording-\(device.id).mp4"),
        data: MediaCommon(capturedAt: Date(), display: DisplayInfo(size: CGSize(width: 100, height: 200), densityScale: 1))
      ))
    }
    await fixture.recording.setCompletedMedia(media)
    fixture.controller.selectDevice(id: second.id)
    await fixture.controller.startRecording()
    let stop = Task { await fixture.controller.stopRecording() }
    await eventually { await fixture.live.stops.count > 0 }
    precondition(fixture.controller.isProcessing && !fixture.controller.canStartRecordingNow)
    await fixture.stopGate.open()
    await stop.value
    precondition(!fixture.controller.isRecording && !fixture.controller.isLivePreviewActive)
    precondition(Set(fixture.controller.mediaList.map(\.id)) == Set(media.map(\.id)))
    precondition(fixture.controller.currentCapture?.media.isVideo == true)
    precondition(fixture.controller.selectedDeviceID == second.id)
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
    let finished = TestValue(false)
    let completion = Task {
      await command.value
      finished.value = true
    }
    await eventually("The queued command must finish while display queries remain blocked") { finished.value }
    await completion.value
  }
}
