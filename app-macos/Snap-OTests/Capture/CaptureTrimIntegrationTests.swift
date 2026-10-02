import AppKit
@preconcurrency import AVFoundation
@testable import Snap_O
import Testing

/// Real media coverage for exported duration, transformed pixels, and source preservation.
struct CaptureTrimIntegrationTests {
  @Test @MainActor
  func nativePlayerMapsMetadataStopTimeAndEndNotification() async throws {
    let fixture = try await TrimVideoFixture.make()
    defer { fixture.remove() }
    let driver = CaptureAVPlaybackDriver()
    defer { driver.stop() }
    let metadata = try await driver.load(fixture.url)
    #expect(abs(metadata.duration - 3) < 0.0001)
    #expect(metadata.frameRate == 10)
    var ended = false
    driver.configure(range: CaptureTrimRange(start: 1.1, end: 1.7), loops: false) { ended = true }
    let item = try #require(driver.player.currentItem)
    #expect(driver.player.actionAtItemEnd == .pause)
    driver.setPlaybackEnd(1.7)
    #expect(abs(item.forwardPlaybackEndTime.seconds - 1.7) < 0.0001)
    driver.setPlaybackEnd(nil)
    #expect(!item.forwardPlaybackEndTime.isValid)
    NotificationCenter.default.post(name: .AVPlayerItemDidPlayToEndTime, object: item)
    #expect(ended)
    ended = false
    driver.stop()
    NotificationCenter.default.post(name: .AVPlayerItemDidPlayToEndTime, object: item)
    #expect(!ended)
    #expect(driver.player.currentItem == nil)
  }

  @Test(arguments: [false, true])
  func exportAppliesTrimAndCropWithoutChangingSource(cropped: Bool) async throws {
    let fixture = try await TrimVideoFixture.make(rotated: true)
    defer { fixture.remove() }
    let original = try Data(contentsOf: fixture.url)
    let destination = fixture.url.deletingLastPathComponent().appendingPathComponent("trim.mp4")
    let crop = cropped ? CGRect(x: 0, y: 0, width: 1, height: 0.5) : CaptureCropGeometry.fullImage
    let result = try await CaptureCropExporter.export(
      fixture.capture, crop: crop, trim: CaptureTrimRange(start: 1.1, end: 1.7), to: destination
    )
    let asset = AVURLAsset(url: destination)
    let duration = try await asset.load(.duration).seconds
    #expect(abs(duration - 0.6) < 0.01)
    #expect(result.id == fixture.capture.id)
    #expect(result.media.size == CGSize(width: 32, height: cropped ? 32 : 64))
    #expect(try Data(contentsOf: fixture.url) == original)
    let generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true
    generator.requestedTimeToleranceBefore = .zero
    generator.requestedTimeToleranceAfter = .zero
    for seconds in [0.0, 0.5] {
      let image = try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
      #expect(image.width == 32 && image.height == (cropped ? 32 : 64))
      let context = try #require(CGContext(
        data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      ))
      context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
      let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
      #expect(bytes[2] > 220 && bytes[0] < 30, "Only blue frames from the selected interval should be exported")
    }
  }

  @Test
  func invalidTrimPreservesDestinationAndSource() async throws {
    let fixture = try await TrimVideoFixture.make()
    defer { fixture.remove() }
    let destination = fixture.url.deletingLastPathComponent().appendingPathComponent("saved.mp4")
    let original = try Data(contentsOf: fixture.url)
    let saved = Data([1, 2, 3])
    try saved.write(to: destination)
    await #expect(throws: (any Error).self) {
      try await CaptureCropExporter.save(
        fixture.capture, crop: CaptureCropGeometry.fullImage, trim: CaptureTrimRange(start: 2, end: 1), to: destination
      )
    }
    #expect(try Data(contentsOf: destination) == saved)
    #expect(try Data(contentsOf: fixture.url) == original)
  }

  @Test @MainActor
  func dragExportUsesConfirmedTrim() async throws {
    let fixture = try await TrimVideoFixture.make()
    defer { fixture.remove() }
    let store = FileStore(baseDir: fixture.url.deletingLastPathComponent().appendingPathComponent("store"))
    defer { store.purgeExistingFiles() }
    let request = CaptureReviewDragExport.Request(
      capture: fixture.capture, crop: CaptureCropGeometry.fullImage, trim: CaptureTrimRange(start: 1.1, end: 1.7)
    )
    let exporter = CaptureReviewDragExport()
    await exporter.prepare(request, fileStore: store)
    defer { exporter.stop() }
    let item = try #require(exporter.draggingItem(for: request, frame: CGRect(x: 0, y: 0, width: 64, height: 32)))
    let url = try #require(item.item as? URL)
    let duration = try await AVURLAsset(url: url).load(.duration).seconds
    #expect(abs(duration - 0.6) < 0.01)
    #expect(!exporter.isReady(for: .init(capture: fixture.capture, crop: CaptureCropGeometry.fullImage)))
  }
}

private struct TrimVideoFixture {
  let url: URL
  let capture: CaptureMedia

  func remove() {
    try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
  }

  static func make(rotated: Bool = false) async throws -> TrimVideoFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let url = root.appendingPathComponent("source.mp4")
    let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
      AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 32,
      AVVideoCompressionPropertiesKey: [AVVideoAllowFrameReorderingKey: false, AVVideoMaxKeyFrameIntervalKey: 30]
    ])
    if rotated { input.transform = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 32, ty: 0) }
    let receiver = writer.inputPixelBufferReceiver(for: input, pixelBufferAttributes: nil)
    try #require(writer.startWriting())
    writer.startSession(atSourceTime: .zero)
    for frame in 0 ..< 30 {
      let buffer = try CVMutablePixelBuffer(.init(
        pixelFormatType: .init(rawValue: kCVPixelFormatType_32BGRA), size: .init(width: 64, height: 32)
      ))
      try buffer.withUnsafeBuffer { pixel in
        CVPixelBufferLockBaseAddress(pixel, [])
        defer { CVPixelBufferUnlockBaseAddress(pixel, []) }
        let bytes = try #require(CVPixelBufferGetBaseAddress(pixel)).assumingMemoryBound(to: UInt8.self)
        for y in 0 ..< 32 {
          for x in 0 ..< 64 {
            let offset = y * CVPixelBufferGetBytesPerRow(pixel) + x * 4
            bytes[offset] = frame >= 10 && frame < 20 ? 255 : 0
            bytes[offset + 1] = frame >= 20 ? 255 : 0
            bytes[offset + 2] = frame < 10 ? 255 : 0
            bytes[offset + 3] = 255
          }
        }
      }
      try await receiver.append(CVReadOnlyPixelBuffer(buffer), with: CMTime(value: Int64(frame), timescale: 10))
    }
    writer.endSession(atSourceTime: CMTime(value: 3, timescale: 1))
    receiver.finish()
    await writer.finishWriting()
    try #require(writer.status == .completed)
    return TrimVideoFixture(url: url, capture: CaptureMedia(
      device: Device(id: "synthetic", model: "Test", androidVersion: "16", vendorModel: nil, manufacturer: nil, avdName: nil),
      media: .video(url: url, capturedAt: Date(), display: DisplayInfo(
        size: CGSize(width: rotated ? 32 : 64, height: rotated ? 64 : 32), densityScale: 1
      ))
    ))
  }
}
