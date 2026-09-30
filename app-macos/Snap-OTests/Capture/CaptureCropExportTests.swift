import AppKit
@preconcurrency import AVFoundation
import ImageIO
@testable import Snap_O
import Testing
import UniformTypeIdentifiers

struct CaptureCropExportTests {
  @Test
  func imageSaveReplacesDestinationWithSelectedPixels() throws {
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
    try #require(CGImageDestinationFinalize(writer))
    try Data([9]).write(to: destination)
    try CaptureCropExporter.saveImage(at: source, crop: CGRect(x: 0.5, y: 0, width: 0.5, height: 1), to: destination)
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
    let size = rotated ? CGSize(width: 32, height: 64) : CGSize(width: 64, height: 32)
    let crop = rotated ? CGRect(x: 0, y: 0.5, width: 1, height: 0.5) : CGRect(x: 0.5, y: 0, width: 0.5, height: 1)
    _ = try await CaptureCropExporter.export(makeCapture(source, size: size, video: true), crop: crop, to: destination)
    let asset = AVURLAsset(url: destination)
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
    _ = try await CaptureCropExporter.export(capture, crop: CaptureCropGeometry.fullImage, to: destination)
    #expect(try Data(contentsOf: destination) == bytes)
  }

  @Test
  func saveReplacesExistingDestination() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("source.png")
    let destination = root.appendingPathComponent("existing.png")
    let bytes = Data([1, 2, 3])
    try bytes.write(to: source)
    try Data([9]).write(to: destination)
    try await CaptureCropExporter.save(
      makeCapture(source, size: CGSize(width: 8, height: 4), video: false),
      crop: CaptureCropGeometry.fullImage, to: destination
    )
    #expect(try Data(contentsOf: destination) == bytes)
  }

  @Test(arguments: [true, false])
  func failedSavePreservesExistingDestination(imageOnly: Bool) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("missing.png")
    let destination = root.appendingPathComponent("existing.png")
    let original = Data([1, 2, 3])
    try original.write(to: destination)
    await #expect(throws: (any Error).self) {
      let crop = CGRect(x: 0, y: 0, width: 0.5, height: 1)
      if imageOnly {
        try CaptureCropExporter.saveImage(at: source, crop: crop, to: destination)
      } else {
        try await CaptureCropExporter.save(
          makeCapture(source, size: CGSize(width: 80, height: 40), video: false), crop: crop, to: destination
        )
      }
    }
    #expect(try Data(contentsOf: destination) == original)
  }

  @Test(arguments: [false, true])
  func exportPreservesExistingDestination(destinationIsSource: Bool) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("source.png")
    let destination = destinationIsSource ? source : root.appendingPathComponent("existing.png")
    let original = Data([1, 2, 3])
    try original.write(to: source)
    try original.write(to: destination)
    let capture = makeCapture(source, size: CGSize(width: 8, height: 4), video: false)
    await #expect(throws: (any Error).self) {
      _ = try await CaptureCropExporter.export(capture, crop: CaptureCropGeometry.fullImage, to: destination)
    }
    #expect(try Data(contentsOf: destination) == original)
  }

  @Test(arguments: [false, true]) @MainActor
  func videoDragProvidesAFileAndMatchingPreview(cropped: Bool) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = FileStore(baseDir: root)
    defer { store.purgeExistingFiles() }
    let source = store.makePreviewDestination(deviceID: "test", capturedAt: Date(), kind: .video)
    try await makeVideo(at: source, rotated: false)
    let capture = makeCapture(source, size: CGSize(width: 64, height: 32), video: true)
    let crop = cropped ? CGRect(x: 0.5, y: 0, width: 0.5, height: 1) : CaptureCropGeometry.fullImage
    let request = CaptureReviewDragExport.Request(capture: capture, crop: crop)
    let exporter = CaptureReviewDragExport()
    await exporter.prepare(request, fileStore: store)

    let frame = CGRect(x: 10, y: 20, width: cropped ? 160 : 320, height: 160)
    let item = try #require(exporter.draggingItem(for: request, frame: frame))
    let exported = try #require(item.item as? URL)
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }
    #expect(pasteboard.writeObjects([exported as NSURL]))
    #expect(pasteboard.string(forType: .fileURL) == exported.absoluteString)
    #expect(exported.pathExtension == "mp4")
    #expect(item.draggingFrame == frame)

    let preview = try #require(item.imageComponentsProvider?().first?.contents as? NSImage)
    let image = try #require(preview.cgImage(forProposedRect: nil, context: nil, hints: nil))
    #expect(image.width == (cropped ? 32 : 64))
    #expect(image.height == 32)
    if cropped {
      let color = try sample(image)
      #expect(color.2 > 220 && color.0 < 30)
    } else {
      #expect(try Data(contentsOf: exported) == Data(contentsOf: source))
    }

    try store.discardPreviews([capture])
    #expect(!FileManager.default.fileExists(atPath: source.path))
    #expect(FileManager.default.fileExists(atPath: exported.path))
    #expect(!exporter.isPreparing)
    #expect(exporter.errorMessage == nil)
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
    try #require(writer.startWriting())
    writer.startSession(atSourceTime: .zero)
    var buffer: CVPixelBuffer?
    try #require(CVPixelBufferCreate(kCFAllocatorDefault, 64, 32, kCVPixelFormatType_32BGRA, nil, &buffer) == kCVReturnSuccess)
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
      try #require(adaptor.append(pixel, withPresentationTime: CMTime(value: Int64(frame), timescale: 10)))
    }
    writer.endSession(atSourceTime: CMTime(value: 3, timescale: 10))
    input.markAsFinished()
    await writer.finishWriting()
    try #require(writer.status == .completed)
  }
}
