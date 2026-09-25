@preconcurrency import AVFoundation
@testable import Snap_O
import Testing

@MainActor
struct LivePreviewDensityTests {
  @Test
  func initialFormatUsesSourceDensity() throws {
    let source = DensityFrameSource()
    let session = LivePreviewSession(deviceID: "test", densityScale: nil, source: source)
    defer { session.cancel() }

    source.send(.density(2.5))
    try source.send(.format(makeFormat()))

    #expect(session.media?.densityScale == 2.5)
  }

  @Test
  func densityChangeNotifiesTheRenderer() throws {
    let source = DensityFrameSource()
    let session = LivePreviewSession(deviceID: "test", densityScale: nil, source: source)
    defer { session.cancel() }
    try source.send(.format(makeFormat()))
    var notifiedDensity: CGFloat?
    session.mediaDidChange = { notifiedDensity = $0.densityScale }

    source.send(.density(3))

    #expect(notifiedDensity == 3)
  }

  private func makeFormat() throws -> CMVideoFormatDescription {
    var format: CMVideoFormatDescription?
    CMVideoFormatDescriptionCreate(
      allocator: kCFAllocatorDefault, codecType: kCMVideoCodecType_H264,
      width: 1080, height: 2400, extensions: nil, formatDescriptionOut: &format
    )
    return try #require(format)
  }
}

@MainActor
private final class DensityFrameSource: LivePreviewFrameSource {
  let hasIndependentFrames = false
  private var receive: ((LivePreviewFrameEvent) -> Void)?

  func start(deliver: @escaping @MainActor @Sendable (LivePreviewFrameEvent) -> Void) {
    receive = deliver
  }

  func send(_ event: LivePreviewFrameEvent) {
    receive?(event)
  }

  func stop() {
    receive = nil
  }
}
