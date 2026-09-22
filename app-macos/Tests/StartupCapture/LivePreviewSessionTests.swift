@preconcurrency import AVFoundation
import Foundation
import OSLog

enum SnapOLog {
  static let recording = Logger(subsystem: "Snap-O.SessionTests", category: "test")
}

enum TestError: Error { case expected }

actor TestGate {
  private var isOpen = false
  private var continuation: CheckedContinuation<Void, Never>?

  func wait() async {
    guard !isOpen else { return }
    await withCheckedContinuation { continuation = $0 }
  }

  func open() {
    isOpen = true
    continuation?.resume()
    continuation = nil
  }
}

/// A blocking stream that only ends when the production session closes it.
final class ScreenStreamSession: @unchecked Sendable {
  private let condition = NSCondition()
  private var isClosed = false

  func read(maxLength _: Int) throws -> Data? {
    condition.lock()
    defer { condition.unlock() }
    while !isClosed {
      condition.wait()
    }
    return nil
  }

  func close() {
    condition.lock()
    isClosed = true
    condition.broadcast()
    condition.unlock()
  }
}

actor RetryDelays {
  private(set) var values: [Duration] = []

  func append(_ delay: Duration) -> Int {
    values.append(delay)
    return values.count
  }
}

actor ADBService {
  private let settingsGate: TestGate?
  private let failsToStart: Bool
  private let failsSettingRead: Bool
  private let failsSettingWrite: Bool
  private var showsTouches: Bool
  private var bootComplete: Bool
  private var bootFailures: Int
  private let blocksBootQuery: Bool
  private(set) var bootQueries = 0
  private(set) var settingsReadStarted = false
  private(set) var writes: [Bool] = []
  private(set) var streamStarts = 0
  private(set) var latestStream: ScreenStreamSession?

  init(
    showsTouches: Bool = false,
    bootComplete: Bool = true,
    bootFailures: Int = 0,
    blocksBootQuery: Bool = false,
    settingsGate: TestGate? = nil,
    failsToStart: Bool = false,
    failsSettingRead: Bool = false,
    failsSettingWrite: Bool = false
  ) {
    self.showsTouches = showsTouches
    self.bootComplete = bootComplete
    self.bootFailures = bootFailures
    self.blocksBootQuery = blocksBootQuery
    self.settingsGate = settingsGate
    self.failsToStart = failsToStart
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

  func displayDensity(deviceID _: String) throws -> Int {
    3
  }

  func startScreenStream(deviceID _: String) throws -> ScreenStreamSession {
    streamStarts += 1
    if failsToStart { throw TestError.expected }
    let stream = ScreenStreamSession()
    latestStream = stream
    return stream
  }

  func getShowTouches(deviceID _: String) async throws -> Bool {
    settingsReadStarted = true
    await settingsGate?.wait()
    if failsSettingRead { throw TestError.expected }
    return showsTouches
  }

  func setShowTouches(deviceID _: String, enabled: Bool) throws {
    writes.append(enabled)
    showsTouches = enabled
    // A failed command may still have changed the device setting.
    if failsSettingWrite { throw TestError.expected }
  }
}

final class H264StreamDecoder: @unchecked Sendable {
  @MainActor static var latest: H264StreamDecoder?
  private let formatHandler: (CMFormatDescription) -> Void
  private let finishLock = NSLock()
  private var finishes = 0

  var finishCount: Int {
    finishLock.withLock { finishes }
  }

  @MainActor
  init(
    sampleHandler _: @escaping (CMSampleBuffer, Bool) -> Void,
    formatHandler: @escaping (CMFormatDescription) -> Void
  ) {
    self.formatHandler = formatHandler
    Self.latest = self
  }

  func append(_: Data) {}
  func finish() {
    dispatchPrecondition(condition: .notOnQueue(.main))
    finishLock.withLock { finishes += 1 }
  }

  @MainActor
  func emitFormat() {
    var format: CMVideoFormatDescription?
    let status = CMVideoFormatDescriptionCreate(
      allocator: kCFAllocatorDefault, codecType: kCMVideoCodecType_H264,
      width: 1080, height: 2400, extensions: nil, formatDescriptionOut: &format
    )
    guard status == noErr, let format else { fatalError("Could not make video format") }
    formatHandler(format)
  }
}

@main
@MainActor
struct LivePreviewSessionTests {
  static func main() async throws {
    let session = try await LivePreviewSession(deviceID: "ready", adb: ADBService())
    precondition(!session.isReady)
    precondition(session.readyAt == nil)
    guard let decoder = H264StreamDecoder.latest else { fatalError("Missing decoder") }
    let first = Task { try await session.waitUntilReady() }
    let second = Task { try await session.waitUntilReady() }
    for _ in 0 ..< 20 {
      await Task.yield()
    }
    H264StreamDecoder.latest?.emitFormat()
    let firstMedia = try await first.value
    let secondMedia = try await second.value
    precondition(firstMedia == secondMedia)
    precondition(firstMedia.size == CGSize(width: 1080, height: 2400))
    precondition(session.isReady)
    let readyAt = session.readyAt
    precondition(readyAt != nil)
    session.cancel()
    precondition(!session.isReady)
    precondition(session.readyAt == readyAt)
    await expectCancellation(Task { try await session.waitUntilReady() })
    _ = await session.waitUntilStop()
    await eventually { decoder.finishCount == 1 }

    let cancelled = try await LivePreviewSession(deviceID: "cancelled", adb: ADBService())
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

    try await streamCompletionFlushesOnce()
    await showTouchesRestoration()
    try await startupRestoresSettings()
    try await startupWaitsForBoot()
    try await readyDeviceDoesNotWait()
    try await bootQueriesRetryWithBackoff()
    for shutdown in [false, true] {
      try await bootWaitCancels(shutdown: shutdown, blocksQuery: false)
      try await bootWaitCancels(shutdown: shutdown, blocksQuery: true)
    }
    print("Live preview session tests passed (readiness, cancellation, cleanup, and overlapping startup)")
  }

  static func startupWaitsForBoot() async throws {
    let adb = ADBService(bootComplete: false)
    let service = LivePreviewService(adb: adb, coordinator: CaptureCoordinator())
    let task = Task { try await service.start(for: "booting", options: LivePreviewOptions(showsTouches: true)) }
    await eventually { await adb.bootQueries > 0 }
    let earlyStarts = await adb.streamStarts
    let earlySettingsRead = await adb.settingsReadStarted
    precondition(earlyStarts == 0 && !earlySettingsRead, "Boot wait must precede streams and settings changes")
    await adb.finishBoot()
    let handle = try await task.value
    let starts = await adb.streamStarts
    precondition(starts == 1)
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
    let starts = await adb.streamStarts
    precondition(queries == 7 && starts == 1, "Failed queries must recover automatically once Android is ready")
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
    let starts = await adb.streamStarts
    let settingsRead = await adb.settingsReadStarted
    precondition(starts == 0 && !settingsRead)
    let lease = try await coordinator.acquire(deviceIDs: ["booting"], for: .livePreview)
    await coordinator.release(lease)
  }

  static func streamCompletionFlushesOnce() async throws {
    let adb = ADBService()
    let session = try await LivePreviewSession(deviceID: "completed", adb: adb)
    guard let decoder = H264StreamDecoder.latest else { fatalError("Missing decoder") }
    await adb.latestStream?.close()
    _ = await session.waitUntilStop()
    session.cancel()
    precondition(decoder.finishCount == 1)
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

    let unreadable = ADBService(failsSettingRead: true)
    let noOverride = await ShowTouchesOverride.apply(deviceID: "unreadable", enabled: true, using: unreadable)
    await noOverride.restore(using: unreadable)
    let skippedWrites = await unreadable.writes
    precondition(skippedWrites.isEmpty)

    let partialWrite = ADBService(failsSettingWrite: true)
    let override = await ShowTouchesOverride.apply(deviceID: "partial-write", enabled: true, using: partialWrite)
    await override.restore(using: partialWrite)
    let restoredWrites = await partialWrite.writes
    precondition(restoredWrites == [true, false])
  }

  enum StartupOutcome: CaseIterable { case success, failure, cancellation }

  static func startupRestoresSettings() async throws {
    for outcome in StartupOutcome.allCases {
      let settingsGate = TestGate()
      let adb = ADBService(settingsGate: settingsGate, failsToStart: outcome == .failure)
      let coordinator = CaptureCoordinator()
      let service = LivePreviewService(adb: adb, coordinator: coordinator)
      var returned = false
      let startup = Task {
        let handle = try await service.start(for: "phone", options: LivePreviewOptions(showsTouches: true))
        returned = true
        return handle
      }
      await eventually { await adb.settingsReadStarted }
      await eventually { await adb.streamStarts == 1 }
      precondition(!returned, "Stream startup must overlap the blocked settings read")
      if outcome == .cancellation { startup.cancel() }
      await settingsGate.open()
      do {
        let handle = try await startup.value
        precondition(outcome == .success)
        let applied = await adb.writes
        precondition(applied == [true])
        _ = await service.stop(handle)
      } catch TestError.expected {
        precondition(outcome == .failure)
      } catch is CancellationError {
        precondition(outcome == .cancellation)
      }
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
