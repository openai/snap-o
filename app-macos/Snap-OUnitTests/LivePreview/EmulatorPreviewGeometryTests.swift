import Foundation
import Testing

struct EmulatorPreviewGeometryTests {
  private let requested = LivePreviewFrameSize.preview(CGSize(width: 540, height: 1200))
  private let native = CGSize(width: 1080, height: 2400)
  private let frame = EmulatorPreviewGeometry.Frame(size: CGSize(width: 540, height: 1200))

  @Test
  func unchangedGeometryReusesTheInitialNativeSize() {
    var geometry = EmulatorPreviewGeometry(requestedSize: requested, nativeSize: native)
    #expect(!geometry.needsNativeSize(for: frame))
    #expect(geometry.update(frame) == .format(displaySize: native))
    #expect(!geometry.needsNativeSize(for: frame))
    #expect(geometry.update(frame) == .unchanged)
  }

  @Test(arguments: [
    EmulatorPreviewGeometry.Frame(size: CGSize(width: 540, height: 1200), rotation: 2),
    EmulatorPreviewGeometry.Frame(size: CGSize(width: 540, height: 1200), configuration: Data([1]))
  ])
  func changedMetadataRequestsNativeSizeEvenWhenPixelDimensionsMatch(changed: EmulatorPreviewGeometry.Frame) {
    var geometry = EmulatorPreviewGeometry(requestedSize: requested, nativeSize: native)
    _ = geometry.update(frame)
    #expect(geometry.needsNativeSize(for: changed))
  }

  @Test
  func changedNativeCapRestartsTheStream() {
    var geometry = EmulatorPreviewGeometry(requestedSize: .preview(CGSize(width: 1600, height: 2000)), nativeSize: native)
    _ = geometry.update(.init(size: CGSize(width: 900, height: 2000)))
    geometry.nativeSize = CGSize(width: 2400, height: 1080)
    #expect(geometry.update(.init(size: CGSize(width: 1080, height: 486), rotation: 1))
      == .restart(nativeSize: CGSize(width: 2400, height: 1080)))
  }

  @Test
  func missingRefreshedSizeRestartsWithNativeFrames() {
    var geometry = EmulatorPreviewGeometry(requestedSize: requested, nativeSize: native)
    _ = geometry.update(frame)
    geometry.nativeSize = nil
    #expect(geometry.update(.init(size: frame.size, rotation: 2)) == .restart(nativeSize: nil))
  }

  @Test
  func aspectMismatchUsesNativeFrames() {
    var geometry = EmulatorPreviewGeometry(requestedSize: requested, nativeSize: native)
    #expect(geometry.update(.init(size: CGSize(width: 540, height: 243), rotation: 1)) == .restart(nativeSize: nil))
  }

  @Test
  func pixelRoundingDoesNotTriggerFallback() {
    var geometry = EmulatorPreviewGeometry(requestedSize: requested, nativeSize: native)
    #expect(geometry.update(.init(size: CGSize(width: 539, height: 1200))) == .format(displaySize: native))
  }

  @Test
  func nativeFallbackNeedsNoSizeQueryAfterRotation() {
    var geometry = EmulatorPreviewGeometry(requestedSize: requested, nativeSize: nil)
    _ = geometry.update(.init(size: native))
    let rotated = EmulatorPreviewGeometry.Frame(size: CGSize(width: 2400, height: 1080), rotation: 1)
    #expect(!geometry.needsNativeSize(for: rotated))
    #expect(geometry.update(rotated) == .format(displaySize: nil))
  }
}
