import AppKit
@preconcurrency import AVFoundation
import Clocks
import Dependencies
import DependenciesTestSupport
import ImageIO
import Synchronization
import Testing
import UniformTypeIdentifiers

@Suite(.dependency(\.continuousClock, ImmediateClock()))
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
    _ = try await CaptureCropExporter.export(
      CaptureExportRequest(
        capture: capture,
        crop: CaptureCropGeometry.fullImage
      ),
      to: destination
    )
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
      CaptureExportRequest(
        capture: makeCapture(source, size: CGSize(width: 8, height: 4), video: false),
        crop: CaptureCropGeometry.fullImage
      ),
      to: destination
    )
    #expect(try Data(contentsOf: destination) == bytes)
  }

  @Test(arguments: [true, false])
  func failedSavePreservesExistingDestination(imageOnly: Bool) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("invalid.png")
    let destination = root.appendingPathComponent("existing.png")
    let original = Data([1, 2, 3])
    let sourceBytes = Data("Invalid image".utf8)
    try sourceBytes.write(to: source)
    try original.write(to: destination)
    await #expect(throws: (any Error).self) {
      let crop = CGRect(x: 0, y: 0, width: 0.5, height: 1)
      if imageOnly {
        try CaptureCropExporter.saveImage(at: source, crop: crop, to: destination)
      } else {
        try await CaptureCropExporter.save(
          CaptureExportRequest(
            capture: makeCapture(source, size: CGSize(width: 80, height: 40), video: false),
            crop: crop
          ),
          to: destination
        )
      }
    }
    #expect(try Data(contentsOf: destination) == original)
    #expect(try Data(contentsOf: source) == sourceBytes)
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
      _ = try await CaptureCropExporter.export(
        CaptureExportRequest(
          capture: capture,
          crop: CaptureCropGeometry.fullImage
        ),
        to: destination
      )
    }
    #expect(try Data(contentsOf: destination) == original)
  }

  @Test
  @MainActor
  func saveDragAndHistoryPassTheSameVideoEdits() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = FileStore(baseDir: root.appendingPathComponent("Drafts"))
    defer { try? FileManager.default.removeItem(at: root) }
    let source = store.makePreviewDestination(deviceID: "test", capturedAt: .now, kind: .video)
    try Data("source".utf8).write(to: source)
    let capture = makeCapture(source, size: CGSize(width: 64, height: 32), video: true)
    let request = CaptureExportRequest(
      capture: capture,
      crop: CGRect(x: 0.5, y: 0, width: 0.5, height: 1),
      trim: CaptureTrimRange(start: 0.1, end: 0.3)
    )
    let received = Mutex<[VideoExportSettings]>([])
    try await withDependencies {
      $0.videoFiles.inspect = { _ in VideoFileInfo(duration: 1, size: CGSize(width: 64, height: 32)) }
      $0.videoFiles.export = { _, settings, destination in
        received.withLock { $0.append(settings) }
        try Data("exported".utf8).write(to: destination)
      }
      $0.videoFiles.thumbnail = { _, size in
        #expect(size == CGSize(width: 640, height: 640))
        return try #require(CGContext(
          data: nil,
          width: 1,
          height: 1,
          bitsPerComponent: 8,
          bytesPerRow: 4,
          space: CGColorSpaceCreateDeviceRGB(),
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )?
          .makeImage())
      }
    } operation: {
      try await store.saveExport(request, to: root.appendingPathComponent("saved.mp4"))
      let drag = CaptureReviewDragExport()
      await drag.prepare(request, fileStore: store)
      #expect(drag.isReady(for: request))
      drag.stop()
      let history = CaptureHistoryRepository(root: root.appendingPathComponent("History"))
      try await store.saveReview([request], name: "Edited video", selectedID: capture.id, history: history)
    }
    let settings = received.withLock { $0 }
    #expect(settings.count == 3)
    for value in settings {
      #expect(value.size == CGSize(width: 32, height: 32))
      #expect(value.transform == CGAffineTransform(translationX: -32, y: 0))
      #expect(value.timeRange?.start.seconds == 0.1)
      #expect(value.timeRange?.end.seconds == 0.3)
    }
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
}
