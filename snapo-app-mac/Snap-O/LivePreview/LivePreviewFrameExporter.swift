import AppKit
import CoreImage

@MainActor
final class LivePreviewFrameExporter {
  struct Frame {
    let url: URL
    let image: NSImage
  }

  private enum ExportError: Error {
    case imageUnavailable
  }

  private let imageContext = CIContext()

  func export(_ pixelBuffer: CVPixelBuffer, to fileStore: FileStore) throws -> Frame {
    let capturedAt = Date()
    let source = CIImage(cvPixelBuffer: pixelBuffer)
    guard let image = imageContext.createCGImage(source, from: source.extent),
          let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
      throw ExportError.imageUnavailable
    }
    let url = try fileStore.makeUniqueDragDestination(capturedAt: capturedAt, kind: .image)
    try data.write(to: url, options: .atomic)
    return Frame(url: url, image: NSImage(cgImage: image, size: .zero))
  }
}
