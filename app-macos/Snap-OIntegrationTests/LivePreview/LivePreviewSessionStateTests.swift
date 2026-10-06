@preconcurrency import AVFoundation
import Clocks
import Dependencies
import DependenciesTestSupport
import Foundation
#if !SNAPO_STANDALONE_TESTS
@testable import Snap_O
#endif
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
    let pending = (0..<2).map { _ in
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

  private enum SourceFailure: Error { case disconnected }

  @MainActor
  private final class Source: LivePreviewFrameSource {
    let hasIndependentFrames = true
    var deliver: (@MainActor @Sendable (LivePreviewFrameEvent) -> Void)?
    var starts = 0
    var stops = 0

    func start(deliver: @escaping @MainActor @Sendable (LivePreviewFrameEvent) -> Void) {
      starts += 1
      self.deliver = deliver
    }

    func format(width: Int32, height: Int32) throws {
      var format: CMVideoFormatDescription?
      let status = CMVideoFormatDescriptionCreate(
        allocator: kCFAllocatorDefault, codecType: kCMVideoCodecType_H264,
        width: width, height: height, extensions: nil, formatDescriptionOut: &format
      )
      #expect(status == noErr)
      deliver?(.format(try #require(format)))
    }

    func stop() { stops += 1; deliver = nil }
    func waitUntilStopped() async {}
  }
}
