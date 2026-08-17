import AppKit
import CoreVideo
import Foundation
import OSLog

enum MediaSaveKind {
  case image
  var fileExtension: String {
    "png"
  }
}

enum SnapOLog {
  static let storage = Logger(subsystem: "Snap-O.FrameExportTests", category: "storage")
}

@main
@MainActor
struct LivePreviewFrameExportTests {
  static func main() throws {
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
    precondition(first.url != second.url)
    let unchanged = try Data(contentsOf: first.url)
    precondition(unchanged == original)
    guard let png = NSBitmapImageRep(data: original),
          let color = png.colorAt(x: 0, y: 0)?.usingColorSpace(.deviceRGB)
    else { fatalError("Could not read exported PNG") }
    precondition(png.pixelsWide == 16 && png.pixelsHigh == 24)
    precondition(color.redComponent > 0.9 && color.blueComponent < 0.1)

    let timestamp = Date()
    let pathA = try store.makeUniqueDragDestination(capturedAt: timestamp, kind: .image)
    let pathB = try store.makeUniqueDragDestination(capturedAt: timestamp, kind: .image)
    precondition(pathA != pathB && pathA.lastPathComponent == pathB.lastPathComponent)
    print("Live preview frame export tests passed")
  }

  private static func makeBuffer() -> CVPixelBuffer {
    var result: CVPixelBuffer?
    let status = CVPixelBufferCreate(
      kCFAllocatorDefault, 16, 24, kCVPixelFormatType_32BGRA,
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
