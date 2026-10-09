@preconcurrency import AVFoundation
import Clocks
import Dependencies
import DependenciesTestSupport
import Foundation
import Testing

@MainActor
@Suite(.dependency(\.continuousClock, TestClock()))
struct LivePreviewSessionStateTests {
  @Test
  func firstFormatReleasesAllReadyWaiters() async throws {
    let source = Source()
    let session = LivePreviewSession(deviceID: "test", densityScale: 3, source: source)
    defer { session.cancel() }
    let entered = TestValue(0)
    let first = Task {
      entered.value += 1
      return try await session.waitUntilReady()
    }
    let second = Task {
      entered.value += 1
      return try await session.waitUntilReady()
    }
    try await waitForState { entered.value == 2 }
    #expect(!session.isReady)
    try source.format(width: 1080, height: 2400)
    let expected = DisplayInfo(size: CGSize(width: 1080, height: 2400), densityScale: 3)
    #expect(try await first.value == expected)
    #expect(try await second.value == expected)
    #expect(try await session.waitUntilReady() == expected)
  }

  @Test
  func streamingTimeStartsWithFirstFormatAndSurvivesRotation() async throws {
    @Dependency(\.continuousClock, as: TestClock<Duration>.self)
    var clock
    let source = Source()
    let session = LivePreviewSession(deviceID: "test", densityScale: nil, source: source)
    defer { session.cancel() }
    await clock.advance(by: .seconds(30))
    #expect(session.streamingDuration == nil)
    try source.format(width: 1080, height: 2400)
    #expect(session.streamingDuration == .zero)
    await clock.advance(by: .seconds(9))
    try source.format(width: 2400, height: 1080)
    #expect(session.streamingDuration == .seconds(9))
  }

  @Test
  func formatAndDensityChangesUpdateDisplayWithoutRestartingSource() throws {
    let source = Source()
    let session = LivePreviewSession(deviceID: "test", densityScale: nil, source: source)
    defer { session.cancel() }
    var changes: [DisplayInfo] = []
    session.displayDidChange = { changes.append($0) }
    try source.format(width: 2, height: 3)
    session.updateDensityScale(3)
    try source.format(width: 3, height: 2)
    #expect(changes == [
      DisplayInfo(size: CGSize(width: 2, height: 3), densityScale: nil),
      DisplayInfo(size: CGSize(width: 2, height: 3), densityScale: 3),
      DisplayInfo(size: CGSize(width: 3, height: 2), densityScale: 3)
    ])
    #expect(session.displayInfo == changes.last)
    #expect(source.starts == 1)
  }

  @Test
  func cancellationReleasesPendingAndFutureReadyWaiters() async throws {
    let source = Source()
    let session = LivePreviewSession(deviceID: "test", densityScale: nil, source: source)
    let entered = TestValue(0)
    let pending = (0 ..< 2).map { _ in
      Task {
        entered.value += 1
        return try await session.waitUntilReady()
      }
    }
    try await waitForState { entered.value == 2 }
    session.cancel()
    session.cancel()
    for task in pending {
      await #expect(throws: CancellationError.self) { try await task.value }
    }
    await #expect(throws: CancellationError.self) { try await session.waitUntilReady() }
    _ = await session.waitUntilStop()
    #expect(source.stops == 1)
    #expect(!session.isReady)
  }

  @Test
  func sourceFailureReleasesReadyWaiterWithItsError() async throws {
    let source = Source()
    let session = LivePreviewSession(deviceID: "test", densityScale: nil, source: source)
    let entered = TestValue(false)
    let ready = Task {
      entered.value = true
      return try await session.waitUntilReady()
    }
    try await waitForState { entered.value }
    source.deliver?(.stopped(SourceFailure.disconnected))
    await #expect(throws: SourceFailure.disconnected) { try await ready.value }
    let failure = await session.waitUntilStop()
    #expect(failure as? SourceFailure == .disconnected)
    #expect(source.stops == 1)
  }

  @Test
  func streamFitsLargestVisibleRendererAndShrinksWhenItLeaves() {
    let source = Source()
    let session = LivePreviewSession(deviceID: "test", densityScale: nil, source: source)
    defer { session.cancel() }
    let small = UUID()
    let large = UUID()
    session.addRenderer(id: small) { _ in }
    session.addRenderer(id: large) { _ in }
    #expect(source.frameSize == .inactive)
    session.updateRendererSize(id: small, pixels: CGSize(width: 400, height: 900))
    session.updateRendererSize(id: large, pixels: CGSize(width: 800, height: 1600))
    #expect(source.frameSize == .preview(CGSize(width: 800, height: 1600)))
    session.updateRendererSize(id: large, pixels: nil)
    #expect(source.frameSize == .preview(CGSize(width: 400, height: 900)))
    session.updateRendererSize(id: large, pixels: CGSize(width: 1200, height: 600))
    #expect(source.frameSize == .preview(CGSize(width: 1200, height: 900)))
    session.removeRenderer(id: large)
    #expect(source.frameSize == .preview(CGSize(width: 400, height: 900)))
    session.removeRenderer(id: small)
    #expect(source.frameSize == .inactive)
    session.updateRendererSize(id: large, pixels: CGSize(width: 1200, height: 600))
    #expect(source.frameSize == .inactive)
  }

  @Test
  func scaledFramesKeepNativeInputCoordinates() throws {
    let source = Source()
    let session = LivePreviewSession(deviceID: "test", densityScale: 3, source: source)
    defer { session.cancel() }
    var format: CMVideoFormatDescription?
    CMVideoFormatDescriptionCreate(
      allocator: kCFAllocatorDefault, codecType: kCMVideoCodecType_H264,
      width: 540, height: 1200, extensions: nil, formatDescriptionOut: &format
    )
    try source.deliver?(.format(#require(format), displaySize: CGSize(width: 1080, height: 2400)))
    #expect(session.displayInfo == DisplayInfo(size: CGSize(width: 1080, height: 2400), densityScale: 3))
  }

  @Test
  func frameSizesRoundUpBoundInvalidInputAndPreserveNativeDemand() {
    #expect(LivePreviewFrameSize.previewSize(CGSize(width: 399.2, height: 899.7)) == .preview(CGSize(width: 400, height: 900)))
    #expect(LivePreviewFrameSize.previewSize(CGSize(width: 0, height: 900)) == .inactive)
    #expect(LivePreviewFrameSize.previewSize(CGSize(width: CGFloat.infinity, height: 900)) == .inactive)
    #expect(LivePreviewFrameSize.previewSize(CGSize(width: 9000, height: 9000)) == .preview(CGSize(width: 8192, height: 8192)))
    #expect(LivePreviewFrameSize.maximum([.inactive, .preview(CGSize(width: 400, height: 900)), .native]) == .native)
  }

  @Test
  func previewRequestsDoNotExceedNativeDimensions() {
    let native = CGSize(width: 1080, height: 2400)
    #expect(LivePreviewFrameSize.preview(CGSize(width: 6016, height: 3384)).capped(to: native) == .preview(native))
    #expect(LivePreviewFrameSize.preview(CGSize(width: 2000, height: 1200)).capped(to: native)
      == .preview(CGSize(width: 1080, height: 1200)))
    #expect(LivePreviewFrameSize.preview(CGSize(width: 540, height: 1200)).capped(to: native)
      == .preview(CGSize(width: 540, height: 1200)))
  }

  @Test
  func previewCapFollowsNativeRotation() {
    let request = LivePreviewFrameSize.preview(CGSize(width: 1500, height: 2000))
    #expect(request.capped(to: CGSize(width: 1920, height: 1200)) == .preview(CGSize(width: 1500, height: 1200)))
    #expect(request.capped(to: CGSize(width: 1200, height: 1920)) == .preview(CGSize(width: 1200, height: 1920)))
  }

  @Test
  func missingNativeSizeUsesFullResolutionFrames() {
    #expect(LivePreviewFrameSize.preview(CGSize(width: 540, height: 1200)).capped(to: nil) == .native)
    #expect(LivePreviewFrameSize.native.capped(to: CGSize(width: 1080, height: 2400)) == .native)
    #expect(LivePreviewFrameSize.inactive.capped(to: nil) == .inactive)
  }

  private enum SourceFailure: Error { case disconnected }

  @MainActor
  private final class Source: LivePreviewFrameSource {
    let hasIndependentFrames = true
    var deliver: (@MainActor @Sendable (LivePreviewFrameEvent) -> Void)?
    var starts = 0
    var stops = 0
    var frameSize = LivePreviewFrameSize.native

    func setFrameSize(_ size: LivePreviewFrameSize) {
      frameSize = size
    }

    func start(deliver: @escaping @MainActor @Sendable (LivePreviewFrameEvent) -> Void) {
      starts += 1
      self.deliver = deliver
    }

    func format(width: Int32, height: Int32) throws {
      var format: CMVideoFormatDescription?
      CMVideoFormatDescriptionCreate(
        allocator: kCFAllocatorDefault, codecType: kCMVideoCodecType_H264,
        width: width, height: height, extensions: nil, formatDescriptionOut: &format
      )
      try deliver?(.format(#require(format)))
    }

    func stop() {
      stops += 1
      deliver = nil
    }

    func waitUntilStopped() async {}
  }
}
