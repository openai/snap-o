import AppKit
import CoreVideo
import Foundation
@testable import Snap_O
import Testing

@MainActor
struct FrameExportTests {
  @Test("Export preserves pixels and never overwrites an earlier capture")
  static func exportsIndependentFrames() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("Snap-O-FrameExport-\(UUID().uuidString)", isDirectory: true)
    let store = FileStore(baseDir: directory)
    defer { store.purgeExistingFiles() }
    let exporter = LivePreviewFrameExporter()
    let buffer = makeBuffer()
    fill(buffer, red: 255, blue: 0)
    let first = try exporter.export(buffer, to: store)
    let original = try Data(contentsOf: first.url)

    fill(buffer, red: 0, blue: 255)
    let second = try exporter.export(buffer, to: store)
    #expect(first.url != second.url)
    let unchanged = try Data(contentsOf: first.url)
    #expect(unchanged == original)
    guard let png = NSBitmapImageRep(data: original),
          let color = png.colorAt(x: 0, y: 0)?.usingColorSpace(.deviceRGB)
    else { fatalError("Could not read exported PNG") }
    #expect(png.pixelsWide == 16 && png.pixelsHigh == 24)
    #expect(color.redComponent > 0.9 && color.blueComponent < 0.1)

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

  private static func fill(_ buffer: CVPixelBuffer, red: UInt8, blue: UInt8) {
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    guard let base = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt8.self) else {
      fatalError("Pixel buffer has no storage")
    }
    for y in 0 ..< CVPixelBufferGetHeight(buffer) {
      for x in 0 ..< CVPixelBufferGetWidth(buffer) {
        let offset = y * CVPixelBufferGetBytesPerRow(buffer) + x * 4
        base[offset] = blue
        base[offset + 1] = 0
        base[offset + 2] = red
        base[offset + 3] = 255
      }
    }
  }
}
