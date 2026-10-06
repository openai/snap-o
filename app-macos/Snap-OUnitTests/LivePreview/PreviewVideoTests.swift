@preconcurrency import AVFoundation
import Clocks
import Dependencies
import DependenciesTestSupport
import Foundation
import Observation
import Testing

@MainActor
@Suite(.dependency(\.continuousClock, TestClock()))
struct PreviewVideoTests {
  @Test
  func quickUncoverWaitsForHiddenStreamCleanup() async throws {
    let cleanup = TestSuspension()
    let first = Source(cleanup: cleanup)
    let second = Source()
    let attempts = TestValue(0)
    let video = PreviewVideo {
      attempts.value += 1
      return LivePreviewSession(
        deviceID: "test", densityScale: nil, source: attempts.value == 1 ? first : second
      )
    } canReconnect: { true }
    video.start()
    try await waitForState { video.session != nil }
    video.setActive(false)
    await cleanup.waitUntilStarted()
    video.setActive(true)
    video.setActive(false)
    video.setActive(true)
    #expect(attempts.value == 1)
    cleanup.resume()
    try await waitForState { attempts.value == 2 }
    #expect(first.stops == 1 && second.starts == 1)
    await video.close()
  }

  @Test
  func closeWaitsForASessionReturnedAfterCancellation() async throws {
    let startup = TestSuspension()
    let source = Source()
    let video = PreviewVideo {
      try? await startup.wait()
      return LivePreviewSession(deviceID: "test", densityScale: nil, source: source)
    } canReconnect: { true }
    video.start()
    await startup.waitUntilStarted()
    let completed = TestValue(false)
    let close = Task { await video.close()
      completed.value = true
    }
    try await waitForState { video.phase == .closed }
    #expect(!completed.value)
    startup.resume()
    await close.value
    #expect(source.starts == 1 && source.stops == 1)
    #expect(video.session == nil)
    await video.close()
    #expect(source.stops == 1)
  }

  @Test
  func restartWaitsForOldVideoCleanup() async throws {
    let cleanup = TestSuspension()
    let first = Source(cleanup: cleanup)
    let second = Source()
    let attempts = TestValue(0)
    let video = PreviewVideo {
      attempts.value += 1
      return LivePreviewSession(
        deviceID: "test", densityScale: nil, source: attempts.value == 1 ? first : second
      )
    } canReconnect: { true }
    video.start()
    try await waitForState { video.session != nil }
    video.restart()
    await cleanup.waitUntilStarted()
    #expect(attempts.value == 1)
    cleanup.resume()
    try await waitForState { attempts.value == 2 }
    #expect(second.starts == 1)
    await video.close()
    #expect(second.stops == 1)
  }

  @Test
  func recoveryDelayStartsAfterFailedSourceCleanup() async throws {
    @Dependency(\.continuousClock, as: TestClock<Duration>.self)
    var clock
    let cleanup = TestSuspension()
    let first = Source(cleanup: cleanup)
    let second = Source()
    let attempts = TestValue(0)
    let video = PreviewVideo {
      attempts.value += 1
      return LivePreviewSession(
        deviceID: "test", densityScale: nil, source: attempts.value == 1 ? first : second
      )
    } canReconnect: { true }
    video.start()
    try await waitForState { first.starts == 1 }
    first.deliver?(.stopped(CocoaError(.fileReadUnknown)))
    await cleanup.waitUntilStarted()
    await clock.advance(by: .seconds(1))
    #expect(attempts.value == 1)
    cleanup.resume()
    try await waitForState { video.phase == .waitingToReconnect }
    await clock.advance(by: .milliseconds(500))
    try await waitForState { attempts.value == 2 }
    await video.close()
    try await clock.checkSuspension()
  }

  @Test
  func failedStartupNeedsExplicitRetry() async throws {
    let source = Source()
    let attempts = TestValue(0)
    let video = PreviewVideo {
      attempts.value += 1
      if attempts.value == 1 { throw CocoaError(.fileReadUnknown) }
      return LivePreviewSession(deviceID: "test", densityScale: nil, source: source)
    } canReconnect: { true }
    video.start()
    try await waitForState {
      if case .failed = video.phase { return true }
      return false
    }
    #expect(attempts.value == 1)
    video.retry()
    try await waitForState { video.session != nil }
    #expect(attempts.value == 2)
    await video.close()
  }

  @Test(arguments: [false, true])
  func slowStartupDoesNotRenewFailedStreamRetries(becomesReady: Bool) async throws {
    @Dependency(\.continuousClock, as: TestClock<Duration>.self)
    var clock
    let sources = TestValue<[Source]>([])
    let video = PreviewVideo {
      let source = Source()
      sources.value.append(source)
      return LivePreviewSession(deviceID: "test", densityScale: nil, source: source)
    } canReconnect: { true }
    video.start()
    let delays: [Duration] = [.milliseconds(500), .seconds(1), .seconds(2), .seconds(3)]
    for attempt in 0 ... 4 {
      try await waitForState { sources.value.count == attempt + 1 }
      await clock.advance(by: .seconds(60))
      if becomesReady { try sources.value[attempt].becomeReady() }
      sources.value[attempt].deliver?(.stopped(CocoaError(.fileReadUnknown)))
      if attempt < 4 {
        try await waitForState { video.phase == .waitingToReconnect }
        await clock.advance(by: delays[attempt])
      }
    }
    try await waitForState { if case .failed = video.phase { true } else { false } }
    #expect(sources.value.count == 5)
    #expect(sources.value.allSatisfy { $0.stops == 1 })
    await video.close()
    try await clock.checkSuspension()
  }

  @Test
  func stableStreamRenewsTheRetryBudget() async throws {
    @Dependency(\.continuousClock, as: TestClock<Duration>.self)
    var clock
    let sources = TestValue<[Source]>([])
    let video = PreviewVideo {
      let source = Source()
      sources.value.append(source)
      return LivePreviewSession(deviceID: "test", densityScale: nil, source: source)
    } canReconnect: { true }
    video.start()
    let delays: [Duration] = [.milliseconds(500), .seconds(1), .seconds(2), .milliseconds(500)]
    for attempt in 0 ... 3 {
      try await waitForState { sources.value.count == attempt + 1 }
      try sources.value[attempt].becomeReady()
      try await waitForState { video.phase == .streaming }
      if attempt == 3 { await clock.advance(by: .seconds(10)) }
      sources.value[attempt].deliver?(.stopped(CocoaError(.fileReadUnknown)))
      try await waitForState { video.phase == .waitingToReconnect }
      await clock.advance(by: delays[attempt])
    }
    try await waitForState { sources.value.count == 5 }
    await video.close()
    try await clock.checkSuspension()
  }

  @Test(arguments: [false, true])
  func pendingRetryEndsWhenClosedOrDisconnected(close: Bool) async throws {
    @Dependency(\.continuousClock, as: TestClock<Duration>.self)
    var clock
    let source = Source()
    let connected = TestValue(true)
    let video = PreviewVideo {
      LivePreviewSession(deviceID: "test", densityScale: nil, source: source)
    } canReconnect: { connected.value }
    video.start()
    try await waitForState { source.starts == 1 }
    source.deliver?(.stopped(CocoaError(.fileReadUnknown)))
    try await waitForState { video.phase == .waitingToReconnect }
    if close { await video.close() } else { connected.value = false }
    await clock.advance(by: .seconds(20))
    #expect(source.starts == 1)
    if !close {
      try await waitForState { if case .failed = video.phase { true } else { false } }
    }
    await video.close()
    try await clock.checkSuspension()
  }

  @Test(arguments: [false, true])
  func recoveryRetriesTransientStartupFailures(restart: Bool) async throws {
    @Dependency(\.continuousClock, as: TestClock<Duration>.self)
    var clock
    let attempts = TestValue(0)
    let first = Source()
    let recovered = Source()
    let video = PreviewVideo {
      attempts.value += 1
      if attempts.value == 2 { throw CocoaError(.fileReadUnknown) }
      return LivePreviewSession(deviceID: "test", densityScale: nil, source: attempts.value == 1 ? first : recovered)
    } canReconnect: { true }
    video.start()
    try await waitForState { first.starts == 1 }
    if restart {
      video.restart()
    } else {
      first.deliver?(.stopped(CocoaError(.fileReadUnknown)))
      try await waitForState { video.phase == .waitingToReconnect }
      await clock.advance(by: .milliseconds(500))
    }
    try await waitForState {
      attempts.value == 2 && video.phase != .starting && video.phase != .waitingForCleanup
    }
    try #require(video.phase == .waitingToReconnect)
    await clock.advance(by: restart ? .milliseconds(500) : .seconds(1))
    try await waitForState { recovered.starts == 1 }
    await video.close()
    #expect(attempts.value == 3)
    try await clock.checkSuspension()
  }

  @Observable
  @MainActor
  fileprivate final class Source: LivePreviewFrameSource {
    let hasIndependentFrames = true
    let cleanup: TestSuspension?
    var starts = 0
    var stops = 0
    var deliver: (@MainActor @Sendable (LivePreviewFrameEvent) -> Void)?
    private var cleanupTask: Task<Void, Never>?
    init(cleanup: TestSuspension? = nil) {
      self.cleanup = cleanup
    }

    func start(deliver: @escaping @MainActor @Sendable (LivePreviewFrameEvent) -> Void) {
      starts += 1
      self.deliver = deliver
    }

    func becomeReady() throws {
      var format: CMVideoFormatDescription?
      CMVideoFormatDescriptionCreate(
        allocator: kCFAllocatorDefault, codecType: kCMVideoCodecType_H264,
        width: 2, height: 3, extensions: nil, formatDescriptionOut: &format
      )
      try deliver?(.format(#require(format)))
    }

    func stop() {
      stops += 1
      deliver = nil
      if let cleanup { cleanupTask = Task { try? await cleanup.wait() } }
    }

    func waitUntilStopped() async {
      await cleanupTask?.value
    }
  }
}
