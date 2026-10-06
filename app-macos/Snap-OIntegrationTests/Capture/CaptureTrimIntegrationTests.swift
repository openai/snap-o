import AppKit
@preconcurrency import AVFoundation
@testable import Snap_O
import Testing

/// Real media coverage for exported duration, transformed pixels, and source preservation.
struct CaptureTrimIntegrationTests {
  @Test(arguments: [false, true])
  func exportAppliesTrimAndCropWithoutChangingSource(cropped: Bool) async throws {
    let fixture = try await TrimVideoFixture.make(rotated: true)
    defer { fixture.remove() }
    let original = try Data(contentsOf: fixture.url)
    let destination = fixture.url.deletingLastPathComponent().appendingPathComponent("trim.mp4")
    let crop = cropped ? CGRect(x: 0, y: 0, width: 1, height: 0.5) : CaptureCropGeometry.fullImage
    let result = try await CaptureCropExporter.export(
      CaptureExportRequest(
        capture: fixture.capture,
        crop: crop,
        trim: CaptureTrimRange(start: 1.1, end: 1.7)
      ),
      to: destination
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

  @Test @MainActor
  func saveUsesTheSameReviewSnapshotAsHistoryExport() async throws {
    let fixture = try await TrimVideoFixture.make()
    defer { fixture.remove() }
    let root = fixture.url.deletingLastPathComponent()
    let store = FileStore(baseDir: root.appendingPathComponent("store"))
    let review = CaptureReviewState(
      batch: ReadyCaptureBatch([fixture.capture], fileStore: store), selectedDeviceID: fixture.capture.device.id,
      fileStore: store, history: CaptureHistory(repository: CaptureHistoryRepository(root: root.appendingPathComponent("saved-history")))
    )
    let itemID = try #require(review.selectedItemID)
    review.setCrop(CGRect(x: 0.5, y: 0, width: 0.5, height: 1), for: itemID)
    review.setTrim(CaptureTrimRange(start: 1.1, end: 1.7), for: itemID)
    let request = try review.exportRequest(for: itemID)
    review.setCrop(CaptureCropGeometry.fullImage, for: itemID)
    review.setTrim(nil, for: itemID)

    let saved = root.appendingPathComponent("saved.mp4")
    let history = root.appendingPathComponent("history.mp4")
    try await CaptureCropExporter.save(request, to: saved)
    _ = try await CaptureCropExporter.export(request, to: history)
    for url in [saved, history] {
      let asset = AVURLAsset(url: url)
      #expect(try await abs(asset.load(.duration).seconds - 0.6) < 0.01)
      let track = try #require(await asset.loadTracks(withMediaType: .video).first)
      #expect(try await track.load(.naturalSize) == CGSize(width: 32, height: 32))
    }
    #expect(FileManager.default.fileExists(atPath: fixture.url.path))
  }

  @Test @MainActor
  func dragExportUsesConfirmedTrim() async throws {
    let fixture = try await TrimVideoFixture.make()
    defer { fixture.remove() }
    let store = FileStore(baseDir: fixture.url.deletingLastPathComponent().appendingPathComponent("store"))
    defer { store.purgeExistingFiles() }
    let request = CaptureExportRequest(
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
