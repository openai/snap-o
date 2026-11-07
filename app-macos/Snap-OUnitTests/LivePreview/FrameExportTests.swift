import AppKit
import CoreVideo
import Foundation
import Testing

@MainActor
struct FrameExportTests {
  @Test("Export writes encoded frames without overwriting an earlier capture")
  static func exportsIndependentFrames() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("Snap-O-FrameExport-\(UUID().uuidString)", isDirectory: true)
    let store = FileStore(baseDir: directory)
    defer { store.purgeExistingFiles() }
    let device = Device(id: "frame-device", model: "Frame Device", androidVersion: "16", vendorModel: nil, manufacturer: nil, avdName: nil)
    let buffer = makeBuffer()
    var encoded = Data("first frame".utf8)
    let image = NSImage(size: CGSize(width: 16, height: 24))
    let exporter = LivePreviewFrameExporter { received in
      #expect(received === buffer)
      return (image, encoded)
    }
    let first = try exporter.export(buffer, device: device, to: store)
    encoded = Data("second frame".utf8)
    let second = try exporter.export(buffer, device: device, to: store)
    #expect(first.url != second.url)
    #expect(first.image === image)
    #expect(try Data(contentsOf: first.url) == Data("first frame".utf8))
    #expect(try Data(contentsOf: second.url) == encoded)

    let timestamp = Date()
    let pathA = try store.makeUniqueDragDestination(capturedAt: timestamp, kind: .image)
    let pathB = try store.makeUniqueDragDestination(capturedAt: timestamp, kind: .image)
    #expect(pathA != pathB && pathA.lastPathComponent == pathB.lastPathComponent)
  }

  private static func makeBuffer(width: Int = 16, height: Int = 24) -> CVPixelBuffer {
    var result: CVPixelBuffer?
    let status = CVPixelBufferCreate(
      kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
      [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &result
    )
    guard status == kCVReturnSuccess, let result else { fatalError("Could not create pixel buffer") }
    return result
  }
}
