@preconcurrency import AVFoundation
import Foundation
import OSLog

enum SnapOLog {
  static let recording = Logger(subsystem: "Snap-O.SessionTests", category: "test")
}

enum TestError: Error { case expected }

actor RetryDelays {
  private(set) var values: [Duration] = []

  func append(_ delay: Duration) -> Int {
    values.append(delay)
    return values.count
  }
}

actor ADBService {
  private let densityGate: TestGate?
  private let settingsGate: TestGate?
  private let failsWake: Bool
  private let wakeGate: TestGate?
  private(set) var keyEvents: [String] = []
  private(set) var densityQueries = 0
  private let failsSettingRead: Bool
  private let failsSettingWrite: Bool
  private var showsTouches: Bool
  private var bootComplete: Bool
  private var densityFailures: Int
  private var bootFailures: Int
  private let blocksBootQuery: Bool
  private(set) var bootQueries = 0
  private var writeGate: TestGate?
  private(set) var commandTimeouts: [Duration?] = []
  private(set) var settingsReadStarted = false
  private(set) var writes: [Bool] = []

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
    if blocksBootQuery { try await Task.sleep(for: .seconds(60)) }
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
    try await readinessWaitersReceiveFirstFormat()
    await cancellationReleasesReadinessWaiters()
    try await independentFramesKeepLatest()
    try formatChangesUpdateMedia()
    try await emulatorFramesDoNotWaitForBoot()
    try await emulatorDensityUpdatesAfterBoot()
    try await emulatorTouchSettingsAreRestored()
    try await stoppingEmulatorCancelsBootSetup()
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

  static func makeSession() -> LivePreviewSession {
    LivePreviewSession(deviceID: "test", densityScale: 3, source: DeviceVideoSource(deviceID: "test"))
  }

  static func readinessWaitersReceiveFirstFormat() async throws {
    let session = makeSession()
    precondition(!session.isReady)
    precondition(session.readyAt == nil)
    defer { session.cancel() }
    let first = Task { try await session.waitUntilReady() }
    let second = Task { try await session.waitUntilReady() }
    for _ in 0 ..< 20 {
      await Task.yield()
    }
    DeviceVideoSource.latest?.emitFormat()
    let firstMedia = try await first.value
    let secondMedia = try await second.value
    precondition(firstMedia == secondMedia)
    precondition(firstMedia.size == CGSize(width: 1080, height: 2400))
    precondition(session.isReady)
    precondition(session.readyAt != nil)
  }

  static func cancellationReleasesReadinessWaiters() async {
    let cancelled = makeSession()
    let pendingFirst = Task { try await cancelled.waitUntilReady() }
    let pendingSecond = Task { try await cancelled.waitUntilReady() }
    for _ in 0 ..< 20 {
      await Task.yield()
    }
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
    let retryGate = TestGate()
    let adb = ADBService(bootComplete: false, densityFailures: 1)
    let service = LivePreviewService(adb: adb, coordinator: CaptureCoordinator()) { _ in await retryGate.wait() }
    let handle = try await service.start(for: "emulator-5554", options: LivePreviewOptions(showsTouches: false))
    let sample = try EmulatorPreviewFrameBuilder().makeSample(rgba: Data(count: 4), width: 1, height: 1, timestamp: 0)!
    EmulatorPreviewFrameSource.latest?.deliver?(.format(CMSampleBufferGetFormatDescription(sample)!))
    await eventually { await adb.bootQueries > 0 }
    await adb.finishBoot()
    await retryGate.open()
    _ = await service.waitUntilInteractive(handle)
    precondition(handle.session.media?.densityScale == 3)
    _ = await service.stop(handle)
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
    let waiting = Task { try await failed.waitUntilReady() }
    await Task.yield()
    failedSource.deliver?(.stopped(TestError.expected))
    do {
      _ = try await waiting.value
      fatalError("A failed source must release readiness waiters")
    } catch TestError.expected {}
  }

  static func startupWaitsForBoot() async throws {
    let adb = ADBService(bootComplete: false)
    let service = LivePreviewService(adb: adb, coordinator: CaptureCoordinator())
    let task = Task { try await service.start(for: "booting", options: LivePreviewOptions(showsTouches: true)) }
    await eventually { await adb.bootQueries > 0 }
    let earlySettingsRead = await adb.settingsReadStarted
    precondition(!earlySettingsRead, "Boot wait must precede settings changes")
    await adb.finishBoot()
    let handle = try await task.value
    _ = await service.stop(handle)
  }

  static func readyDeviceDoesNotWait() async throws {
    let adb = ADBService()
    let service = LivePreviewService(adb: adb, coordinator: CaptureCoordinator()) { _ in
      fatalError("A ready device must not wait before connecting")
    }
    let handle = try await service.start(for: "ready", options: LivePreviewOptions(showsTouches: false))
    let queries = await adb.bootQueries
    precondition(queries == 1)
    _ = await service.stop(handle)
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
    let adb = ADBService(bootComplete: false, bootFailures: 2)
    let delays = RetryDelays()
    let service = LivePreviewService(adb: adb, coordinator: CaptureCoordinator()) { delay in
      if await delays.append(delay) == 6 { await adb.finishBoot() }
    }
    let handle = try await service.start(for: "booting", options: LivePreviewOptions(showsTouches: false))
    let observedDelays = await delays.values
    precondition(observedDelays == [1, 2, 4, 8, 10, 10].map { .seconds($0) })
    let queries = await adb.bootQueries
    precondition(queries == 7, "Failed queries must recover automatically once Android is ready")
    _ = await service.stop(handle)
  }

  static func bootWaitCancels(shutdown: Bool, blocksQuery: Bool) async throws {
    let adb = ADBService(bootComplete: false, blocksBootQuery: blocksQuery)
    let coordinator = CaptureCoordinator()
    let delays = RetryDelays()
    let service = LivePreviewService(adb: adb, coordinator: coordinator) { delay in
      _ = await delays.append(delay)
      if delay == .seconds(10) { try await Task.sleep(for: .seconds(60)) }
    }
    let task = Task { try await service.start(for: "booting", options: LivePreviewOptions(showsTouches: true)) }
    if blocksQuery {
      await eventually { await adb.bootQueries > 0 }
    } else {
      await eventually { await delays.values.last == .seconds(10) }
    }
    let rescue = Task {
      try await Task.sleep(for: .seconds(2))
      task.cancel()
    }
    defer { rescue.cancel() }
    let start = ContinuousClock.now
    if shutdown { await service.shutdown() } else { task.cancel() }
    do {
      _ = try await task.value
      fatalError("Boot wait should have ended without starting a stream")
    } catch is CancellationError {
      // Both caller cancellation and shutdown must interrupt discovery immediately.
    }
    precondition(start.duration(to: .now) < .seconds(1), "Cancellation must interrupt the probe or backoff sleep")
    let settingsRead = await adb.settingsReadStarted
    precondition(!settingsRead)
    let lease = try await coordinator.acquire(deviceIDs: ["booting"], for: .livePreview)
    await coordinator.release(lease)
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
      var returned = false
      let recording = Task {
        let lease = await ShowTouchesOverride.apply(
          deviceID: deviceID, enabled: false, using: adb,
          timeout: cancel ? .seconds(30) : .milliseconds(30)
        )
        returned = true
        return lease
      }
      // Let the second owner join the pending read before cancelling it.
      try? await Task.sleep(for: .milliseconds(10))
      if cancel { recording.cancel() }
      await eventually { returned }
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
    let abandoned = await ShowTouchesOverride.apply(
      deviceID: "abandoned-setup", enabled: true, using: adb, timeout: .milliseconds(30)
    )
    await abandoned.restore(using: adb)
    await gate.open()
    await eventually { await adb.writes == [true, false] }

    for cancel in [false, true] {
      let adb = ADBService()
      let lease = await ShowTouchesOverride.apply(deviceID: "blocked-restore-\(cancel)", enabled: true, using: adb)
      let gate = TestGate()
      await adb.blockWrites(on: gate)
      var returned = false
      let restore = Task {
        await lease.restore(using: adb, timeout: cancel ? .seconds(30) : .milliseconds(30))
        returned = true
      }
      await eventually { await gate.waitCount == 1 }
      if cancel { restore.cancel() }
      await eventually { returned }
      await restore.value
      await gate.open()
      await eventually { await adb.writes == [true, false] }
    }
  }

  static func shutdownDuringTouchSetup() async throws {
    let gate = TestGate()
    let adb = ADBService(settingsGate: gate)
    let coordinator = CaptureCoordinator()
    let service = LivePreviewService(adb: adb, coordinator: coordinator)
    let startup = Task {
      try await service.start(for: "shutdown-settings", options: LivePreviewOptions(showsTouches: true))
    }
    await eventually { await adb.settingsReadStarted }
    var stopped = false
    let shutdown = Task {
      await service.shutdown()
      stopped = true
    }
    await eventually { stopped }
    await shutdown.value
    do {
      _ = try await startup.value
      fatalError("Startup must not succeed after shutdown")
    } catch is CancellationError {
      // Expected while the device is still unresponsive.
    }
    let lease = try await coordinator.acquire(deviceIDs: ["shutdown-settings"], for: .livePreview)
    await coordinator.release(lease)
    await gate.open()
    await eventually { await adb.writes == [true, false] }
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
      await eventually { DeviceVideoSource.latest != nil }
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
      let lease = try await coordinator.acquire(deviceIDs: ["phone"], for: .livePreview)
      await coordinator.release(lease)
    }
  }

  static func eventually(_ condition: () async -> Bool) async {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while ContinuousClock.now < deadline {
      if await condition() { return }
      await Task.yield()
    }
    fatalError("Condition did not become true")
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
  static var latest: DeviceVideoSource?

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
