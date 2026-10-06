@preconcurrency import AVFoundation
import Clocks
import DependenciesTestSupport
import Observation
#if !SNAPO_STANDALONE_TESTS
@testable import Snap_O
#endif
import Testing

@MainActor
@Suite(.dependency(\.continuousClock, TestClock()))
struct SharedPreviewVideoTests {
  @Test
  func suspendingPreviewKeepsRecordingSubscriptionStreaming() async throws {
    let source = FrameSource()
    let hub = DeviceVideoHub { _ in source }
    let target = DeviceTarget(serial: "emulator-5554", transportID: "1")
    let recordingSource = DeviceVideoSource(target: target, hub: hub)
    var recordedFrames = 0
    recordingSource.start { event in
      if case .sample = event { recordedFrames += 1 }
    }
    let video = PreviewVideo {
      session(target, hub)
    } canReconnect: { true }
    video.start()
    try await waitForState { video.session != nil }
    try source.sendFrame(1)
    video.setActive(false)
    try await waitForState { video.session == nil }
    try source.sendFrame(2)
    #expect(recordedFrames == 2)
    #expect(source.starts == 1 && source.stops == 0)
    video.setActive(true)
    try await waitForState { video.phase == .streaming }
    try source.sendFrame(3)
    #expect(recordedFrames == 3)
    #expect(source.starts == 1)
    await video.close()
    #expect(source.stops == 0)
    recordingSource.stop()
    await recordingSource.waitUntilStopped()
    #expect(source.stops == 1)
  }

  @Test
  func oneSessionKeepsOtherRenderersWhenAViewLeaves() async throws {
    let source = FrameSource()
    let session = LivePreviewSession(deviceID: "emulator-5554", densityScale: nil, source: source)
    let first = UUID()
    let second = UUID()
    var firstFrames = 0
    var secondFrames = 0
    session.addRenderer(id: first) { _ in firstFrames += 1 }
    try source.sendFrame(1)
    session.addRenderer(id: second) { _ in secondFrames += 1 }
    #expect(firstFrames == 1 && secondFrames == 1, "A joining view receives the current emulator frame")
    session.removeRenderer(id: first)
    try source.sendFrame(2)
    #expect(firstFrames == 1 && secondFrames == 2)
    #expect(source.stops == 0)
    session.cancel()
    _ = await session.waitUntilStop()
    #expect(source.stops == 1)
  }

  @Test
  func joiningRendererWaitsForKeyframeWithoutInterruptingExistingRenderer() async throws {
    let source = FrameSource(independent: false)
    let session = LivePreviewSession(deviceID: "physical-device", densityScale: nil, source: source)
    var firstFrames = 0
    var secondFrames = 0
    session.addRenderer(id: UUID()) { _ in firstFrames += 1 }
    let sample = try #require(try EmulatorPreviewFrameBuilder().makeSample(
      rgba: Data(repeating: 0, count: 64), width: 4, height: 4, timestamp: 1
    ))
    try source.deliver?(.format(#require(CMSampleBufferGetFormatDescription(sample))))
    source.deliver?(.sample(sample, isKeyFrame: true))
    session.addRenderer(id: UUID()) { _ in secondFrames += 1 }
    source.deliver?(.sample(sample, isKeyFrame: false))
    #expect(firstFrames == 2 && secondFrames == 0)
    source.deliver?(.sample(sample, isKeyFrame: true))
    #expect(firstFrames == 3 && secondFrames == 1)
    session.cancel()
    _ = await session.waitUntilStop()
  }

  @Test
  func windowsShareFramesAndCloseIndependently() async throws {
    let source = FrameSource()
    let hub = DeviceVideoHub { _ in source }
    let target = DeviceTarget(serial: "emulator-5554", transportID: "1")
    let first = session(target, hub)
    let second = session(target, hub)
    var firstFrames = 0
    var secondFrames = 0
    first.addRenderer(id: UUID()) { _ in firstFrames += 1 }
    second.addRenderer(id: UUID()) { _ in secondFrames += 1 }
    try source.sendFrame(1)
    #expect(source.starts == 1)
    #expect(firstFrames == 1 && secondFrames == 1)
    first.cancel()
    _ = await first.waitUntilStop()
    #expect(source.stops == 0)
    try source.sendFrame(2)
    #expect(firstFrames == 1 && secondFrames == 2)
    second.cancel()
    _ = await second.waitUntilStop()
    #expect(source.stops == 1)
  }

  @Test
  func joiningAnIdleEmulatorGetsItsLastFrame() async throws {
    let source = FrameSource()
    let hub = DeviceVideoHub { _ in source }
    let target = DeviceTarget(serial: "emulator-5554", transportID: "1")
    let first = session(target, hub)
    try source.sendFrame(42)
    let second = session(target, hub)
    var timestamps: [Int64] = []
    second.addRenderer(id: UUID()) { timestamps.append(CMSampleBufferGetPresentationTimeStamp($0).value) }
    #expect(timestamps == [42])
    first.cancel()
    second.cancel()
    _ = await first.waitUntilStop()
    _ = await second.waitUntilStop()
  }

  @Test
  func unmountedRendererRetainsOnlyTheLatestIndependentFrame() async throws {
    let source = FrameSource()
    let hub = DeviceVideoHub { _ in source }
    let target = DeviceTarget(serial: "emulator-5554", transportID: "1")
    let unmounted = session(target, hub)
    let visible = session(target, hub)
    var visibleCount = 0
    visible.addRenderer(id: UUID()) { _ in visibleCount += 1 }
    for index in 1 ... 20 {
      try source.sendFrame(UInt64(index))
    }
    var pending: [Int64] = []
    unmounted.addRenderer(id: UUID()) { pending.append(CMSampleBufferGetPresentationTimeStamp($0).value) }
    #expect(visibleCount == 20)
    #expect(pending == [20])
    unmounted.cancel()
    visible.cancel()
    _ = await unmounted.waitUntilStop()
    _ = await visible.waitUntilStop()
  }

  @Test
  func stalledRendererCannotExhaustTheSharedEmulatorBuffers() async throws {
    let source = FrameSource()
    let hub = DeviceVideoHub { _ in source }
    let target = DeviceTarget(serial: "emulator-5554", transportID: "1")
    let stalled = session(target, hub)
    let healthy = session(target, hub)
    let stalledBuffer = LivePreviewFrameBuffer()
    let healthyBuffer = LivePreviewFrameBuffer()
    var heldFrames: [CMSampleBuffer] = []
    var healthyCount = 0
    stalled.addRenderer(id: UUID()) {
      if let frame = stalledBuffer.copyForDisplay($0) { heldFrames.append(frame) }
    }
    healthy.addRenderer(id: UUID()) {
      if healthyBuffer.copyForDisplay($0) != nil { healthyCount += 1 }
    }
    for index in 1 ... 20 {
      try source.sendFrame(UInt64(index))
    }
    #expect(heldFrames.count == 4)
    #expect(healthyCount == 20)
    heldFrames.removeLast()
    try source.sendFrame(21)
    #expect(heldFrames.count == 4, "The stalled renderer can resume as soon as it releases a buffer")
    stalled.cancel()
    healthy.cancel()
    _ = await stalled.waitUntilStop()
    _ = await healthy.waitUntilStop()
  }

  @Test
  func displayCopyPreservesPixelsAndTimeWithoutRetainingTheSourceBuffer() throws {
    let builder = EmulatorPreviewFrameBuilder()
    let original = try #require(try builder.makeSample(
      rgba: Data([255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255, 10, 20, 30, 255]),
      width: 2, height: 2, timestamp: 123
    ))
    let copied = try #require(LivePreviewFrameBuffer().copyForDisplay(original))
    #expect(CMSampleBufferGetPresentationTimeStamp(copied) == CMSampleBufferGetPresentationTimeStamp(original))
    let source = try #require(CMSampleBufferGetImageBuffer(original))
    let pixels = try #require(CMSampleBufferGetImageBuffer(copied))
    #expect(source !== pixels)
    CVPixelBufferLockBaseAddress(pixels, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
    let bytes = try #require(CVPixelBufferGetBaseAddress(pixels)).assumingMemoryBound(to: UInt8.self)
    let stride = CVPixelBufferGetBytesPerRow(pixels)
    #expect(Array(UnsafeBufferPointer(start: bytes, count: 8)) == [0, 0, 255, 255, 0, 255, 0, 255])
    #expect(Array(UnsafeBufferPointer(start: bytes + stride, count: 8)) == [255, 0, 0, 255, 30, 20, 10, 255])
  }

  @Test
  func sourceFailureReachesEveryWindowAndReplacementWaitsForCleanup() async throws {
    let cleanup = TestSuspension()
    let firstSource = FrameSource(cleanup: cleanup)
    let nextSource = FrameSource()
    var creations = 0
    let hub = DeviceVideoHub { _ in
      creations += 1
      return creations == 1 ? firstSource : nextSource
    }
    let target = DeviceTarget(serial: "emulator-5554", transportID: "1")
    let first = session(target, hub)
    let second = session(target, hub)
    firstSource.deliver?(.stopped(CocoaError(.fileReadUnknown)))
    #expect(firstSource.stops == 1)
    let firstError = Task { await first.waitUntilStop() }
    let secondError = Task { await second.waitUntilStop() }
    let replacement = session(target, hub)
    await cleanup.waitUntilStarted()
    #expect(nextSource.starts == 0)
    cleanup.resume()
    #expect(await firstError.value != nil)
    #expect(await secondError.value != nil)
    try await waitForState { nextSource.starts == 1 }
    replacement.cancel()
    _ = await replacement.waitUntilStop()
  }

  @Test
  func replacementConnectionDoesNotShareTheOldSource() async {
    var sources: [FrameSource] = []
    let hub = DeviceVideoHub { _ in
      let source = FrameSource()
      sources.append(source)
      return source
    }
    let oldTarget = DeviceTarget(serial: "emulator-5554", transportID: "1")
    let newTarget = DeviceTarget(serial: "emulator-5554", transportID: "2")
    let old = session(oldTarget, hub)
    let next = session(newTarget, hub)
    #expect(sources.count == 2)
    old.cancel()
    _ = await old.waitUntilStop()
    #expect(sources[1].stops == 0)
    next.cancel()
    _ = await next.waitUntilStop()
  }

  @Test
  func synchronousFailureStillReleasesTheSource() async {
    let source = FrameSource(failOnStart: true)
    let hub = DeviceVideoHub { _ in source }
    let target = DeviceTarget(serial: "emulator-5554", transportID: "1")
    let failed = session(target, hub)
    #expect(await failed.waitUntilStop() != nil)
    #expect(source.stops == 1)
  }

  private func session(_ target: DeviceTarget, _ hub: DeviceVideoHub) -> LivePreviewSession {
    LivePreviewSession(deviceID: target.serial, densityScale: nil, source: DeviceVideoSource(target: target, hub: hub))
  }

  @Observable
  @MainActor
  fileprivate final class FrameSource: LivePreviewFrameSource {
    let hasIndependentFrames: Bool
    let cleanup: TestSuspension?
    let failOnStart: Bool
    var starts = 0
    var stops = 0
    var deliver: (@MainActor @Sendable (LivePreviewFrameEvent) -> Void)?
    private var cleanupTask: Task<Void, Never>?
    private let frames = EmulatorPreviewFrameBuilder()

    init(cleanup: TestSuspension? = nil, failOnStart: Bool = false, independent: Bool = true) {
      hasIndependentFrames = independent
      self.cleanup = cleanup
      self.failOnStart = failOnStart
    }

    func start(deliver: @escaping @MainActor @Sendable (LivePreviewFrameEvent) -> Void) {
      starts += 1
      self.deliver = deliver
      if failOnStart { deliver(.stopped(CocoaError(.fileReadUnknown))) }
    }

    func sendFrame(_ timestamp: UInt64) throws {
      let sample = try #require(try frames.makeSample(
        rgba: Data(repeating: 0, count: 64), width: 4, height: 4, timestamp: timestamp
      ))
      try deliver?(.format(#require(CMSampleBufferGetFormatDescription(sample))))
      deliver?(.sample(sample, isKeyFrame: true))
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
