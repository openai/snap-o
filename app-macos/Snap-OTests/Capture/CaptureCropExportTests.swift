import AppKit
@preconcurrency import AVFoundation
import ImageIO
@testable import Snap_O
import Testing
import UniformTypeIdentifiers

struct CaptureCropExportTests {
  @Test
  func imageExportUsesSelectedPixelsAndLeavesSourceIntact() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("source.png")
    let destination = root.appendingPathComponent("crop.png")
    let context = try #require(CGContext(
      data: nil,
      width: 80,
      height: 40,
      bitsPerComponent: 8,
      bytesPerRow: 320,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    context.setFillColor(NSColor.red.cgColor)
    context.fill(CGRect(x: 0, y: 0, width: 80, height: 40))
    context.setFillColor(NSColor.blue.cgColor)
    context.fill(CGRect(x: 40, y: 0, width: 40, height: 40))
    let writer = try #require(CGImageDestinationCreateWithURL(source as CFURL, UTType.png.identifier as CFString, 1, nil))
    try CGImageDestinationAddImage(writer, #require(context.makeImage()), nil)
    #expect(CGImageDestinationFinalize(writer))
    let original = try Data(contentsOf: source)
    let capture = makeCapture(source, size: CGSize(width: 80, height: 40), video: false)
    let result = try await CaptureCropExporter.export(capture, crop: CGRect(x: 0.5, y: 0, width: 0.5, height: 1), to: destination)
    #expect(result.media.size == CGSize(width: 40, height: 40))
    #expect(result.id == capture.id)
    try Data([9]).write(to: destination)
    try await CaptureCropExporter.save(capture, crop: CGRect(x: 0.5, y: 0, width: 0.5, height: 1), to: destination)
    #expect(try Data(contentsOf: source) == original)
    let image = try CaptureCropExporter.image(at: destination, crop: CaptureCropGeometry.fullImage)
    let color = try sample(image)
    #expect(color.2 > 240 && color.0 < 15)
  }

  @Test(arguments: [false, true])
  func videoExportBakesCropAndOrientation(rotated: Bool) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("source.mp4")
    let destination = root.appendingPathComponent("crop.mp4")
    try await makeVideo(at: source, rotated: rotated)
    let original = try Data(contentsOf: source)
    let size = rotated ? CGSize(width: 32, height: 64) : CGSize(width: 64, height: 32)
    let crop = rotated ? CGRect(x: 0, y: 0.5, width: 1, height: 0.5) : CGRect(x: 0.5, y: 0, width: 0.5, height: 1)
    let result = try await CaptureCropExporter.export(makeCapture(source, size: size, video: true), crop: crop, to: destination)
    #expect(result.media.size == CGSize(width: 32, height: 32))
    try Data([9]).write(to: destination)
    try await CaptureCropExporter.save(makeCapture(source, size: size, video: true), crop: crop, to: destination)
    #expect(try Data(contentsOf: source) == original)
    let asset = AVURLAsset(url: destination)
    #expect(try await asset.load(.duration).seconds >= 0.25)
    let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
    #expect(try await track.load(.naturalSize) == CGSize(width: 32, height: 32))
    let generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true
    let frame = try await generator.image(at: .zero).image
    let color = try sample(frame)
    #expect(color.2 > 220 && color.0 < 30)
  }

  @Test @MainActor
  func uncroppedExportIsAnExactCopy() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("source.mp4")
    let destination = root.appendingPathComponent("copy.mp4")
    let bytes = Data([1, 2, 3, 4])
    try bytes.write(to: source)
    let capture = makeCapture(source, size: CGSize(width: 64, height: 32), video: true)
    let promise = CaptureCropFilePromise(capture: capture, crop: CaptureCropGeometry.fullImage)
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      promise.filePromiseProvider(promise, writePromiseTo: destination) { error in
        if let error { continuation.resume(throwing: error) }
        else { continuation.resume() }
      }
    }
    #expect(try Data(contentsOf: destination) == bytes)
  }

  @Test
  func failedSavePreservesExistingDestination() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("missing.png")
    let destination = root.appendingPathComponent("existing.png")
    let original = Data([1, 2, 3])
    try original.write(to: destination)
    await #expect(throws: (any Error).self) {
      try await CaptureCropExporter.save(
        makeCapture(source, size: CGSize(width: 80, height: 40), video: false),
        crop: CGRect(x: 0, y: 0, width: 0.5, height: 1), to: destination
      )
    }
    #expect(try Data(contentsOf: destination) == original)
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["existing.png"])
  }

  private func sample(_ image: CGImage) throws -> (UInt8, UInt8, UInt8) {
    let context = try #require(CGContext(
      data: nil,
      width: 1,
      height: 1,
      bitsPerComponent: 8,
      bytesPerRow: 4,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
    let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
    return (bytes[0], bytes[1], bytes[2])
  }

  private func makeCapture(_ url: URL, size: CGSize, video: Bool) -> CaptureMedia {
    let display = DisplayInfo(size: size, densityScale: 2)
    return CaptureMedia(
      device: Device(
        id: "test",
        model: "Test",
        androidVersion: "16",
        vendorModel: nil,
        manufacturer: nil,
        avdName: nil
      ),
      media: video ? .video(url: url, capturedAt: Date(), display: display)
        : .image(url: url, capturedAt: Date(), display: display)
    )
  }

  private func makeVideo(at url: URL, rotated: Bool) async throws {
    let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
      AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 32,
      AVVideoCompressionPropertiesKey: [AVVideoAllowFrameReorderingKey: false]
    ])
    if rotated { input.transform = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 32, ty: 0) }
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
    writer.add(input)
    #expect(writer.startWriting())
    writer.startSession(atSourceTime: .zero)
    var buffer: CVPixelBuffer?
    #expect(CVPixelBufferCreate(kCFAllocatorDefault, 64, 32, kCVPixelFormatType_32BGRA, nil, &buffer) == kCVReturnSuccess)
    let pixel = try #require(buffer)
    CVPixelBufferLockBaseAddress(pixel, [])
    let bytes = try #require(CVPixelBufferGetBaseAddress(pixel)).assumingMemoryBound(to: UInt8.self)
    for y in 0 ..< 32 {
      for x in 0 ..< 64 {
        let offset = y * CVPixelBufferGetBytesPerRow(pixel) + x * 4
        bytes[offset] = x >= 32 ? 255 : 0
        bytes[offset + 1] = 0
        bytes[offset + 2] = x < 32 ? 255 : 0
        bytes[offset + 3] = 255
      }
    }
    CVPixelBufferUnlockBaseAddress(pixel, [])
    for frame in 0 ..< 3 {
      while !input.isReadyForMoreMediaData {
        try await Task.sleep(for: .milliseconds(1))
      }
      #expect(adaptor.append(pixel, withPresentationTime: CMTime(value: Int64(frame), timescale: 10)))
    }
    writer.endSession(atSourceTime: CMTime(value: 3, timescale: 10))
    input.markAsFinished()
    await writer.finishWriting()
    #expect(writer.status == .completed)
  }
}
