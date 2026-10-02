@preconcurrency import AVFoundation
import Clocks
import ConcurrencyExtras
import Dependencies
import Foundation
import OSLog

enum SnapOLog {
  static let recording = Logger(subsystem: "Snap-O.SessionTests", category: "test")
}

enum TestError: Error { case expected }

actor ADBService {
  private let densityGate: TestGate?
  private let settingsGate: TestGate?
  private let failsWake: Bool
  private let wakeGate: TestGate?
  private(set) var keyEvents: [String] = [] {
    didSet { testChanges.signal() }
  }

  private(set) var densityQueries = 0 {
    didSet { testChanges.signal() }
  }

  private let failsSettingRead: Bool
  private let failsSettingWrite: Bool
  private var showsTouches: Bool
  private var bootComplete: Bool
  private var densityFailures: Int
  private var bootFailures: Int
  private let blocksBootQuery: Bool
  private(set) var bootQueries = 0 {
    didSet { testChanges.signal() }
  }

  private var writeGate: TestGate?
  private(set) var commandTimeouts: [Duration?] = [] {
    didSet { testChanges.signal() }
  }

  private(set) var settingsReadStarted = false {
    didSet { testChanges.signal() }
  }

  private(set) var writes: [Bool] = [] {
    didSet { testChanges.signal() }
  }

  init(
    showsTouches: Bool = false,
    bootComplete: Bool = true,
    bootFailures: Int = 0,
    densityFailures: Int = 0,
    blocksBootQuery: Bool = false,
    densityGate: TestGate? = nil,
    settingsGate: TestGate? = nil,
    failsWake: Bool = false,
    wakeGate: TestGate? = nil,
    failsSettingRead: Bool = false,
    failsSettingWrite: Bool = false
  ) {
    self.showsTouches = showsTouches
    self.bootComplete = bootComplete
    self.bootFailures = bootFailures
    self.densityFailures = densityFailures
    self.blocksBootQuery = blocksBootQuery
    self.densityGate = densityGate
    self.settingsGate = settingsGate
    self.failsWake = failsWake
    self.wakeGate = wakeGate
    self.failsSettingRead = failsSettingRead
    self.failsSettingWrite = failsSettingWrite
  }

  func exec() -> ADBService {
    self
  }

  func isBootComplete(deviceID _: String) async throws -> Bool {
    bootQueries += 1
    if blocksBootQuery { try await suspendUntilCancelled() }
    if bootFailures > 0 {
      bootFailures -= 1
      throw TestError.expected
    }
    return bootComplete
  }

  func finishBoot() {
    bootComplete = true
  }

  func keyEvent(deviceID _: String, keyCode: String) async throws {
    keyEvents.append(keyCode)
    await wakeGate?.wait()
    if failsWake { throw TestError.expected }
  }

  func displayDensity(deviceID _: String) async throws -> Int {
    densityQueries += 1
    await densityGate?.wait()
    if densityFailures > 0 {
      densityFailures -= 1
      throw TestError.expected
    }
    return 3
  }

  func withTimeout(_ timeout: Duration?) -> ADBService {
    commandTimeouts.append(timeout)
    return self
  }

  func blockWrites(on gate: TestGate) {
    writeGate = gate
  }

  func getShowTouches(deviceID _: String) async throws -> Bool {
    settingsReadStarted = true
    await settingsGate?.wait()
    if failsSettingRead { throw TestError.expected }
    return showsTouches
  }

  func setShowTouches(deviceID _: String, enabled: Bool) async throws {
    await writeGate?.wait()
    writes.append(enabled)
    showsTouches = enabled
    // A failed command may still have changed the device setting.
    if failsSettingWrite { throw TestError.expected }
  }
}

@main
@MainActor
struct LivePreviewSessionTests {
  static func main() async throws {
    try await withMainSerialExecutor {
      try await withDependencies {
        $0.context = .test
        $0.continuousClock = TestClock()
      } operation: {
        try await readinessWaitersReceiveFirstFormat()
        await streamingDurationStartsAtFirstFormat()
        await cancellationReleasesReadinessWaiters()
        try await independentFramesKeepLatest()
        try formatChangesUpdateMedia()
        try await emulatorFramesDoNotWaitForBoot()
        try await emulatorDensityUpdatesAfterBoot()
        try await emulatorTouchSettingsAreRestored()
        try await stoppingEmulatorCancelsBootSetup()
        try await previewsStopIndependently()
        try await sourceFailureReleasesReadinessWaiters()
        cancellationStopsSourceOnce()
        await showTouchesRestoration()
        await touchSettingWaitsAreBounded()
        try await shutdownDuringTouchSetup()
        try await startupRestoresSettings()
        try await startupWaitsForBoot()
        try await readyDeviceDoesNotWait()
        try await physicalPreviewWakesDevice()
        try await physicalPreviewWaitsForWakeBeforeStartingSource()
        try await wakeFailureDoesNotPreventPreview()
        try await cancellationDuringWakeDoesNotStartSource()
        try await physicalPreviewDoesNotQueryDensity()
        try await bootQueriesRetryWithBackoff()
        for shutdown in [false, true] {
          try await bootWaitCancels(shutdown: shutdown, blocksQuery: false)
          try await bootWaitCancels(shutdown: shutdown, blocksQuery: true)
        }
        print("Live preview session tests passed (readiness, cancellation, cleanup, and overlapping startup)")
      }
    }
  }

  static func makeSession() -> LivePreviewSession {
    LivePreviewSession(deviceID: "test", densityScale: 3, source: DeviceVideoSource(deviceID: "test"))
  }

  static func readinessWaitersReceiveFirstFormat() async throws {
    let session = makeSession()
    precondition(!session.isReady)
    precondition(session.streamingDuration == nil)
    defer { session.cancel() }
    let entered = TestValue(0)
    let first = Task { entered.value += 1
      return try await session.waitUntilReady()
    }
    let second = Task { entered.value += 1
      return try await session.waitUntilReady()
    }
    await waitForObservedTestState { entered.value == 2 }
    DeviceVideoSource.latest?.emitFormat()
    let firstMedia = try await first.value
    let secondMedia = try await second.value
    precondition(firstMedia == secondMedia)
    precondition(firstMedia.size == CGSize(width: 1080, height: 2400))
    precondition(session.isReady)
    precondition(session.streamingDuration != nil)
  }

  static func streamingDurationStartsAtFirstFormat() async {
    let clock = TestClock()
    let session = withDependencies { $0.continuousClock = clock } operation: { makeSession() }
    defer { session.cancel() }
    await clock.advance(by: .seconds(30))
    precondition(session.streamingDuration == nil, "Startup does not count as streaming time")
    DeviceVideoSource.latest?.emitFormat()
    precondition(session.streamingDuration == .zero)
    await clock.advance(by: .seconds(9))
    DeviceVideoSource.latest?.emitFormat()
    precondition(session.streamingDuration == .seconds(9), "Later formats do not reset streaming time")
    await clock.advance(by: .seconds(1))
    precondition(session.streamingDuration == .seconds(10))
  }

  static func cancellationReleasesReadinessWaiters() async {
    let cancelled = makeSession()
    let entered = TestValue(0)
    let pendingFirst = Task { entered.value += 1
      return try await cancelled.waitUntilReady()
    }
    let pendingSecond = Task { entered.value += 1
      return try await cancelled.waitUntilReady()
    }
    await waitForObservedTestState { entered.value == 2 }
    cancelled.cancel()
    precondition(!cancelled.isReady)
    await expectCancellation(pendingFirst)
    await expectCancellation(pendingSecond)
    await expectCancellation(Task { try await cancelled.waitUntilReady() })
    _ = await cancelled.waitUntilStop()
  }

  static func independentFramesKeepLatest() async throws {
    let source = TestRawFrameSource()
    let session = LivePreviewSession(deviceID: "emulator-5554", densityScale: 3, source: source)
    let builder = EmulatorPreviewFrameBuilder()
    let pixels = Data(repeating: 255, count: 1080 * 2400 * 4)
    for timestamp: UInt64 in [1, 2, 3] {
      let sample = try builder.makeSample(rgba: pixels, width: 1080, height: 2400, timestamp: timestamp)!
      source.deliver?(.format(CMSampleBufferGetFormatDescription(sample)!))
      source.deliver?(.sample(sample, isKeyFrame: true))
    }
    var received: [CMSampleBuffer] = []
    session.sampleBufferHandler = { received.append($0) }
    precondition(received.count == 1, "Only the latest independent frame should be retained")
    precondition(CMSampleBufferGetPresentationTimeStamp(received[0]).value == 3)
    session.cancel()
  }

  static func formatChangesUpdateMedia() throws {
    let source = TestRawFrameSource()
    let session = LivePreviewSession(deviceID: "test", densityScale: 3, source: source)
    defer { session.cancel() }
    var sizes: [CGSize] = []
    session.mediaDidChange = { sizes.append($0.size) }
    let builder = EmulatorPreviewFrameBuilder()
    for (width, height) in [(2, 3), (3, 2)] {
      let sample = try builder.makeSample(rgba: Data(count: 24), width: width, height: height, timestamp: 0)!
      source.deliver?(.format(CMSampleBufferGetFormatDescription(sample)!))
    }
    precondition(sizes == [CGSize(width: 2, height: 3), CGSize(width: 3, height: 2)])
    precondition(session.media?.size == sizes.last)
  }

  static func emulatorFramesDoNotWaitForBoot() async throws {
    let adb = ADBService(bootComplete: false, blocksBootQuery: true)
    let service = LivePreviewService(adb: adb, coordinator: CaptureCoordinator())
    let handle = try await service.start(for: "emulator-5554", options: LivePreviewOptions(showsTouches: true))
    let source = EmulatorPreviewFrameSource.latest!
    let sample = try EmulatorPreviewFrameBuilder().makeSample(rgba: Data(count: 24), width: 2, height: 3, timestamp: 0)!
    source.deliver?(.format(CMSampleBufferGetFormatDescription(sample)!))
    let media = try await handle.session.waitUntilReady()
    precondition(media.size == CGSize(width: 2, height: 3) && media.densityScale == nil)
    _ = await service.stop(handle)
  }

  static func emulatorDensityUpdatesAfterBoot() async throws {
    let clock = TestClock()
    try await withDependencies { $0.continuousClock = clock } operation: {
      let adb = ADBService(bootComplete: false, densityFailures: 1)
      let service = LivePreviewService(adb: adb, coordinator: CaptureCoordinator())
      let handle = try await service.start(for: "emulator-5554", options: LivePreviewOptions(showsTouches: false))
      let sample = try EmulatorPreviewFrameBuilder().makeSample(rgba: Data(count: 4), width: 1, height: 1, timestamp: 0)!
      EmulatorPreviewFrameSource.latest?.deliver?(.format(CMSampleBufferGetFormatDescription(sample)!))
      await eventually { await adb.bootQueries > 0 }
      await adb.finishBoot()
      await clock.advance(by: .seconds(1))
      await eventually { await adb.densityQueries == 1 }
      await clock.advance(by: .seconds(1))
      _ = await service.waitUntilInteractive(handle)
      precondition(handle.session.media?.densityScale == 3)
      _ = await service.stop(handle)
    }
  }

  static func emulatorTouchSettingsAreRestored() async throws {
    let adb = ADBService()
    let service = LivePreviewService(adb: adb, coordinator: CaptureCoordinator())
    let handle = try await service.start(for: "emulator-5554", options: LivePreviewOptions(showsTouches: true))
    _ = await service.waitUntilInteractive(handle)
    _ = await service.stop(handle)
    let writes = await adb.writes
    precondition(writes == [true, false])
  }

  static func stoppingEmulatorCancelsBootSetup() async throws {
    let adb = ADBService(bootComplete: false, blocksBootQuery: true)
    let service = LivePreviewService(adb: adb, coordinator: CaptureCoordinator())
    let handle = try await service.start(for: "emulator-5554", options: LivePreviewOptions(showsTouches: true))
    await eventually { await adb.bootQueries > 0 }
    _ = await service.stop(handle)
    let writes = await adb.writes
    precondition(writes.isEmpty, "Stopping during boot must cancel deferred Android setup")
  }

  static func previewsStopIndependently() async throws {
    for deviceID in ["shared-phone", "emulator-5554"] {
      for stopsFirstPreview in [false, true] {
        let adb = ADBService()
        let coordinator = CaptureCoordinator()
        let service = LivePreviewService(adb: adb, coordinator: coordinator)
        let options = LivePreviewOptions(showsTouches: true)
        let isEmulator = EmulatorGRPCEndpoint.isEmulator(deviceID)
        let first = try await service.start(for: deviceID, options: options)
        let firstSource: TestRawFrameSource = isEmulator ? EmulatorPreviewFrameSource.latest! : DeviceVideoSource.latest!
        let second = try await service.start(for: deviceID, options: options)
        let secondSource: TestRawFrameSource = isEmulator ? EmulatorPreviewFrameSource.latest! : DeviceVideoSource.latest!
        precondition(first.session !== second.session)
        _ = await service.waitUntilInteractive(first)
        _ = await service.waitUntilInteractive(second)

        let stopped = stopsFirstPreview ? first : second
        let stoppedSource = stopsFirstPreview ? firstSource : secondSource
        let remaining = stopsFirstPreview ? second : first
        let remainingSource = stopsFirstPreview ? secondSource : firstSource
        _ = await service.stop(stopped)
        _ = await service.stop(stopped)
        precondition(stoppedSource.stops == 1 && remainingSource.stops == 0)
        let activeWrites = await adb.writes
        precondition(activeWrites == [true], "Closing one preview must retain shared touch settings")

        let sample = try EmulatorPreviewFrameBuilder().makeSample(rgba: Data(count: 4), width: 1, height: 1, timestamp: 0)!
        var frames = 0
        remaining.session.sampleBufferHandler = { _ in frames += 1 }
        remainingSource.deliver?(.format(CMSampleBufferGetFormatDescription(sample)!))
        remainingSource.deliver?(.sample(sample, isKeyFrame: true))
        precondition(remaining.session.isReady && frames == 1, "The other preview must keep receiving frames")
        do {
          _ = try await coordinator.acquire(deviceIDs: [deviceID], for: .bugReportRecording)
          fatalError("The remaining preview must retain its capture lease")
        } catch CaptureCoordinationError.deviceBusy(let busyDeviceID, let activity) {
          precondition(busyDeviceID == deviceID && activity == .livePreview)
        }

        _ = await service.stop(remaining)
        precondition(remainingSource.stops == 1)
        let finalWrites = await adb.writes
        precondition(finalWrites == [true, false], "Closing the final preview must restore touch settings")
        await coordinator.waitUntilIdle()
      }
    }
  }

  static func cancellationStopsSourceOnce() {
    let source = TestRawFrameSource()
    let session = LivePreviewSession(deviceID: "test", densityScale: 3, source: source)
    session.cancel()
    session.cancel()
    precondition(source.stops == 1)
  }

  static func sourceFailureReleasesReadinessWaiters() async throws {
    let failedSource = TestRawFrameSource()
    let failed = LivePreviewSession(deviceID: "emulator-5554", densityScale: 3, source: failedSource)
    let entered = TestValue(false)
    let waiting = Task { entered.value = true
      return try await failed.waitUntilReady()
    }
    await waitForObservedTestState { entered.value }
    failedSource.deliver?(.stopped(TestError.expected))
    do {
      _ = try await waiting.value
      fatalError("A failed source must release readiness waiters")
    } catch TestError.expected {}
  }

  static func startupWaitsForBoot() async throws {
    let clock = TestClock()
    try await withDependencies { $0.continuousClock = clock } operation: {
      let adb = ADBService(bootComplete: false)
      let service = LivePreviewService(adb: adb, coordinator: CaptureCoordinator())
      let task = Task { try await service.start(for: "booting", options: LivePreviewOptions(showsTouches: true)) }
      await eventually { await adb.bootQueries > 0 }
      let earlySettingsRead = await adb.settingsReadStarted
      precondition(!earlySettingsRead, "Boot wait must precede settings changes")
      await adb.finishBoot()
      await clock.advance(by: .seconds(1))
      let handle = try await task.value
      _ = await service.stop(handle)
    }
  }

  static func readyDeviceDoesNotWait() async throws {
    let clock = TestClock()
    try await withDependencies { $0.continuousClock = clock } operation: {
      let adb = ADBService()
      let service = LivePreviewService(adb: adb, coordinator: CaptureCoordinator())
      let handle = try await service.start(for: "ready", options: LivePreviewOptions(showsTouches: false))
      let queries = await adb.bootQueries
      precondition(queries == 1)
      _ = await service.stop(handle)
      try await clock.checkSuspension()
    }
  }

  static func physicalPreviewWakesDevice() async throws {
    let adb = ADBService()
    let service = LivePreviewService(adb: adb, coordinator: CaptureCoordinator())
    let handle = try await service.start(for: "phone", options: LivePreviewOptions(showsTouches: false))
    let keys = await adb.keyEvents
    precondition(keys == ["KEYCODE_WAKEUP"])
    _ = await service.stop(handle)
  }

  static func physicalPreviewWaitsForWakeBeforeStartingSource() async throws {
    let gate = TestGate()
    let adb = ADBService(wakeGate: gate)
    let service = LivePreviewService(adb: adb, coordinator: CaptureCoordinator())
    DeviceVideoSource.latest = nil
    let startup = Task { try await service.start(for: "phone", options: LivePreviewOptions(showsTouches: false)) }
    await eventually { await gate.waitCount == 1 }
    precondition(DeviceVideoSource.latest == nil)
    await gate.open()
    _ = try await service.stop(startup.value)
  }

  static func wakeFailureDoesNotPreventPreview() async throws {
    let adb = ADBService(failsWake: true)
    let service = LivePreviewService(adb: adb, coordinator: CaptureCoordinator())
    DeviceVideoSource.latest = nil
    let handle = try await service.start(for: "phone", options: LivePreviewOptions(showsTouches: false))
    precondition(DeviceVideoSource.latest != nil)
    _ = await service.stop(handle)
  }

  static func cancellationDuringWakeDoesNotStartSource() async throws {
    let gate = TestGate()
    let adb = ADBService(wakeGate: gate)
    let service = LivePreviewService(adb: adb, coordinator: CaptureCoordinator())
    DeviceVideoSource.latest = nil
    let startup = Task { try await service.start(for: "phone", options: LivePreviewOptions(showsTouches: false)) }
    await eventually { await gate.waitCount == 1 }
    startup.cancel()
    await gate.open()
    _ = await startup.result
    precondition(DeviceVideoSource.latest == nil)
  }

  static func physicalPreviewDoesNotQueryDensity() async throws {
    let adb = ADBService()
    let service = LivePreviewService(adb: adb, coordinator: CaptureCoordinator())
    let handle = try await service.start(for: "phone", options: LivePreviewOptions(showsTouches: false))
    _ = await service.waitUntilInteractive(handle)
    let queries = await adb.densityQueries
    precondition(queries == 0)
    _ = await service.stop(handle)
  }

  static func bootQueriesRetryWithBackoff() async throws {
    let clock = TestClock()
    try await withDependencies { $0.continuousClock = clock } operation: {
      let adb = ADBService(bootComplete: false, bootFailures: 2)
      let service = LivePreviewService(adb: adb, coordinator: CaptureCoordinator())
      let startup = Task { try await service.start(for: "booting", options: LivePreviewOptions(showsTouches: false)) }
      await eventually { await adb.bootQueries == 1 }
      for (index, seconds) in [1, 2, 4, 8, 10, 10].enumerated() {
        await clock.advance(by: .seconds(seconds) - .milliseconds(1))
        let beforeRetry = await adb.bootQueries
        precondition(beforeRetry == index + 1, "Do not retry before the backoff deadline")
        if index == 5 { await adb.finishBoot() }
        await clock.advance(by: .milliseconds(1))
        await eventually { await adb.bootQueries == index + 2 }
      }
      let handle = try await startup.value
      let queries = await adb.bootQueries
      precondition(queries == 7, "Failed queries must recover automatically once Android is ready")
      _ = await service.stop(handle)
    }
  }

  static func bootWaitCancels(shutdown: Bool, blocksQuery: Bool) async throws {
    let clock = TestClock()
    try await withDependencies { $0.continuousClock = clock } operation: {
      let adb = ADBService(bootComplete: false, blocksBootQuery: blocksQuery)
      let coordinator = CaptureCoordinator()
      let service = LivePreviewService(adb: adb, coordinator: coordinator)
      let task = Task { try await service.start(for: "booting", options: LivePreviewOptions(showsTouches: true)) }
      if blocksQuery {
        await eventually { await adb.bootQueries > 0 }
      } else {
        await eventually { await adb.bootQueries == 1 }
        for (index, seconds) in [1, 2, 4, 8].enumerated() {
          await clock.advance(by: .seconds(seconds))
          await eventually { await adb.bootQueries == index + 2 }
        }
      }
      if shutdown { await service.shutdown() } else { task.cancel() }
      do {
        _ = try await task.value
        fatalError("Boot wait should have ended without starting a stream")
      } catch is CancellationError {
        // Both caller cancellation and shutdown must interrupt discovery immediately.
      }
      let settingsRead = await adb.settingsReadStarted
      precondition(!settingsRead)
      let lease = try await coordinator.acquire(deviceIDs: ["booting"], for: .bugReportRecording)
      await coordinator.release(lease)
    }
  }

  static func showTouchesRestoration() async {
    for original in [false, true] {
      for requested in [false, true] {
        let adb = ADBService(showsTouches: original)
        let override = await ShowTouchesOverride.apply(deviceID: "settings", enabled: requested, using: adb)
        await override.restore(using: adb)
        let writes = await adb.writes
        precondition(writes == (original == requested ? [] : [requested, original]))
      }
    }

    let sharedSettings = ADBService(showsTouches: false)
    let preview = await ShowTouchesOverride.apply(deviceID: "shared-settings", enabled: true, using: sharedSettings)
    let recording = await ShowTouchesOverride.apply(deviceID: "shared-settings", enabled: true, using: sharedSettings)
    await preview.restore(using: sharedSettings)
    let writesWhileRecording = await sharedSettings.writes
    precondition(writesWhileRecording == [true], "Ending preview must preserve the recording setting")
    await recording.restore(using: sharedSettings)
    let finalWrites = await sharedSettings.writes
    precondition(finalWrites == [true, false], "The final consumer must restore the original setting")

    for original in [false, true] {
      for firstRequested in [false, true] {
        for recordingEndsFirst in [false, true] {
          let adb = ADBService(showsTouches: original)
          let preview = await ShowTouchesOverride.apply(deviceID: "changed-settings", enabled: firstRequested, using: adb)
          let recording = await ShowTouchesOverride.apply(deviceID: "changed-settings", enabled: !firstRequested, using: adb)
          var expected = original == firstRequested ? [] : [firstRequested]
          expected.append(!firstRequested)
          let applied = await adb.writes
          precondition(applied == expected, "A new consumer must apply the latest preference")
          await (recordingEndsFirst ? recording : preview).restore(using: adb)
          let sharedWrites = await adb.writes
          precondition(sharedWrites == expected, "The latest preference stays active until the final consumer exits")
          await (recordingEndsFirst ? preview : recording).restore(using: adb)
          expected.append(original)
          let restored = await adb.writes
          precondition(restored == expected, "Restore the original value even when the first consumer did not change it")
        }
      }
    }

    let unreadable = ADBService(failsSettingRead: true)
    let noOverride = await ShowTouchesOverride.apply(deviceID: "unreadable", enabled: true, using: unreadable)
    await noOverride.restore(using: unreadable)
    let skippedWrites = await unreadable.writes
    precondition(skippedWrites.isEmpty)

    let failedUpdate = ADBService(showsTouches: false, failsSettingWrite: true)
    let first = await ShowTouchesOverride.apply(deviceID: "failed-update", enabled: true, using: failedUpdate)
    let second = await ShowTouchesOverride.apply(deviceID: "failed-update", enabled: false, using: failedUpdate)
    await first.restore(using: failedUpdate)
    await second.restore(using: failedUpdate)
    let retriedRestore = await failedUpdate.writes
    precondition(retriedRestore == [true, false, false], "A failed preference update must not skip final restoration")

    let partialWrite = ADBService(failsSettingWrite: true)
    let override = await ShowTouchesOverride.apply(deviceID: "partial-write", enabled: true, using: partialWrite)
    await override.restore(using: partialWrite)
    let restoredWrites = await partialWrite.writes
    precondition(restoredWrites == [true, false])
  }

  static func touchSettingWaitsAreBounded() async {
    for cancel in [false, true] {
      let gate = TestGate()
      let adb = ADBService(settingsGate: gate)
      let deviceID = "shared-wait-\(cancel)"
      let preview = Task {
        await ShowTouchesOverride.apply(deviceID: deviceID, enabled: true, using: adb)
      }
      await eventually { await adb.settingsReadStarted }
      let clock = TestClock()
      let recording = withDependencies { $0.continuousClock = clock } operation: { Task {
        await ShowTouchesOverride.apply(
          deviceID: deviceID, enabled: false, using: adb
        )
      } }
      await clock.advance()
      if cancel { recording.cancel() } else { await clock.advance(by: .seconds(3)) }
      let abandoned = await recording.value
      await abandoned.restore(using: adb)
      let pendingWrites = await adb.writes
      precondition(pendingWrites.isEmpty, "A caller must return while the shared read is blocked")
      await gate.open()
      let active = await preview.value
      // Join the latest preference to wait for its queued write to finish.
      let joined = await ShowTouchesOverride.apply(deviceID: deviceID, enabled: false, using: adb)
      await joined.restore(using: adb)
      await active.restore(using: adb)
      let writes = await adb.writes
      precondition(writes == [true, false, false], "The remaining owner must retain shared work and restore the original")
      let timeouts = await adb.commandTimeouts
      precondition(timeouts.allSatisfy { $0 == .seconds(3) }, "Every shared command needs its own deadline")
    }

    let gate = TestGate()
    let adb = ADBService(settingsGate: gate)
    let clock = TestClock()
    let setup = withDependencies { $0.continuousClock = clock } operation: { Task {
      await ShowTouchesOverride.apply(
        deviceID: "abandoned-setup", enabled: true, using: adb
      )
    } }
    await eventually { await gate.waitCount == 1 }
    await clock.advance(by: .seconds(3))
    let abandoned = await setup.value
    await abandoned.restore(using: adb)
    await gate.open()
    await eventually { await adb.writes == [true, false] }

    for cancel in [false, true] {
      let adb = ADBService()
      let lease = await ShowTouchesOverride.apply(deviceID: "blocked-restore-\(cancel)", enabled: true, using: adb)
      let gate = TestGate()
      await adb.blockWrites(on: gate)
      let clock = TestClock()
      let restore = withDependencies { $0.continuousClock = clock } operation: { Task {
        await lease.restore(using: adb)
      } }
      await eventually { await gate.waitCount == 1 }
      await clock.advance()
      if cancel { restore.cancel() } else { await clock.advance(by: .seconds(3)) }
      await restore.value
      await gate.open()
      await eventually { await adb.writes == [true, false] }
    }
  }

  static func shutdownDuringTouchSetup() async throws {
    let clock = TestClock()
    try await withDependencies { $0.continuousClock = clock } operation: {
      let gate = TestGate()
      let adb = ADBService(settingsGate: gate)
      let coordinator = CaptureCoordinator()
      let service = LivePreviewService(adb: adb, coordinator: coordinator)
      let startup = Task {
        try await service.start(for: "shutdown-settings", options: LivePreviewOptions(showsTouches: true))
      }
      await eventually { await adb.settingsReadStarted }
      let shutdown = Task { await service.shutdown() }
      await clock.advance(by: .seconds(3))
      await shutdown.value
      do {
        _ = try await startup.value
        fatalError("Startup must not succeed after shutdown")
      } catch is CancellationError {
        // Expected while the device is still unresponsive.
      }
      let lease = try await coordinator.acquire(deviceIDs: ["shutdown-settings"], for: .bugReportRecording)
      await coordinator.release(lease)
      await gate.open()
      await eventually { await adb.writes == [true, false] }
    }
  }

  enum StartupOutcome: CaseIterable { case success, cancellation }

  static func startupRestoresSettings() async throws {
    for outcome in StartupOutcome.allCases {
      let settingsGate = TestGate()
      let adb = ADBService(settingsGate: settingsGate)
      DeviceVideoSource.latest = nil
      let coordinator = CaptureCoordinator()
      let service = LivePreviewService(adb: adb, coordinator: coordinator)
      var returned = false
      let startup = Task {
        let handle = try await service.start(for: "phone", options: LivePreviewOptions(showsTouches: true))
        returned = true
        return handle
      }
      await eventually { await adb.settingsReadStarted }
      await waitForActorTestState { DeviceVideoSource.latest != nil }
      precondition(!returned, "Stream startup must overlap the blocked settings read")
      if outcome == .cancellation { startup.cancel() }
      await settingsGate.open()
      do {
        let handle = try await startup.value
        precondition(outcome == .success)
        let applied = await adb.writes
        precondition(applied == [true])
        _ = await service.stop(handle)
      } catch is CancellationError {
        precondition(outcome == .cancellation)
      }
      await eventually { await adb.writes == [true, false] }
      let writes = await adb.writes
      precondition(writes == [true, false], "Every exit must restore the previous device setting")
      let lease = try await coordinator.acquire(deviceIDs: ["phone"], for: .bugReportRecording)
      await coordinator.release(lease)
    }
  }

  static func eventually(_ condition: () async -> Bool) async {
    await waitForActorTestState(condition)
  }

  static func expectCancellation(_ task: Task<Media, Error>) async {
    do {
      _ = try await task.value
      fatalError("Expected cancellation")
    } catch is CancellationError {
      // Expected.
    } catch {
      fatalError("Unexpected error: \(error)")
    }
  }
}

@MainActor
class TestRawFrameSource: LivePreviewFrameSource {
  let hasIndependentFrames = true
  var deliver: (@MainActor @Sendable (LivePreviewFrameEvent) -> Void)?
  var stops = 0

  func start(deliver: @escaping @MainActor @Sendable (LivePreviewFrameEvent) -> Void) {
    self.deliver = deliver
  }

  func stop() {
    stops += 1
  }
}

@MainActor
final class EmulatorPreviewFrameSource: TestRawFrameSource {
  static var latest: EmulatorPreviewFrameSource?

  init(deviceID _: String) {
    super.init()
    Self.latest = self
  }
}

@MainActor
final class DeviceVideoSource: TestRawFrameSource {
  static var latest: DeviceVideoSource? {
    didSet { testChanges.signal() }
  }

  init(deviceID _: String) {
    super.init()
    Self.latest = self
  }

  func emitFormat() {
    var format: CMVideoFormatDescription?
    let status = CMVideoFormatDescriptionCreate(
      allocator: kCFAllocatorDefault, codecType: kCMVideoCodecType_H264,
      width: 1080, height: 2400, extensions: nil, formatDescriptionOut: &format
    )
    guard status == noErr, let format else { fatalError("Could not make video format") }
    deliver?(.format(format))
  }
}
