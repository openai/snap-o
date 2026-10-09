@preconcurrency import AVFoundation
import Foundation
import Testing

struct EmulatorPreviewFrameBuilderTests {
  @Test
  func expandsRGBToOpaqueBGRAWithPaddedRows() throws {
    let builder = EmulatorPreviewFrameBuilder()
    let rgb = Data([255, 0, 0, 0, 255, 0, 0, 0, 255, 10, 20, 30, 40, 50, 60, 70, 80, 90])
    let sample = try #require(try builder.makeSample(rgb: rgb, width: 3, height: 2, timestamp: 123_456))
    let pixels = try #require(CMSampleBufferGetImageBuffer(sample))
    CVPixelBufferLockBaseAddress(pixels, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
    let bytes = try #require(CVPixelBufferGetBaseAddress(pixels)).assumingMemoryBound(to: UInt8.self)
    let stride = CVPixelBufferGetBytesPerRow(pixels)
    #expect(Array(UnsafeBufferPointer(start: bytes, count: 12)) == [0, 0, 255, 255, 0, 255, 0, 255, 255, 0, 0, 255])
    #expect(Array(UnsafeBufferPointer(start: bytes + stride, count: 12)) == [30, 20, 10, 255, 60, 50, 40, 255, 90, 80, 70, 255])
    #expect(CMSampleBufferGetPresentationTimeStamp(sample) == CMTime(value: 123_456, timescale: 1_000_000))
  }

  @Test
  func rejectsIncompleteRGBFrames() {
    let builder = EmulatorPreviewFrameBuilder()
    #expect(throws: EmulatorPreviewError.self) {
      try builder.makeSample(rgb: Data(count: 11), width: 2, height: 2, timestamp: 0)
    }
  }

  @Test
  func retainedRGBFramesStayBoundedAndSurviveResizing() throws {
    let builder = EmulatorPreviewFrameBuilder()
    let rgb = Data(repeating: 100, count: 12)
    var retained = try (0 ..< 4).map { index in
      try #require(try builder.makeSample(rgb: rgb, width: 2, height: 2, timestamp: UInt64(index)))
    }
    #expect(try builder.makeSample(rgb: rgb, width: 2, height: 2, timestamp: 4) == nil)
    retained.removeLast()
    let resumed = try #require(try builder.makeSample(rgb: rgb, width: 2, height: 2, timestamp: 5))
    let resized = try #require(try builder.makeSample(rgb: Data(count: 9), width: 3, height: 1, timestamp: 6))
    #expect(try CVPixelBufferGetWidth(#require(CMSampleBufferGetImageBuffer(resized))) == 3)
    #expect(try CVPixelBufferGetWidth(#require(CMSampleBufferGetImageBuffer(resumed))) == 2)
    withExtendedLifetime(retained) {}
  }
}
