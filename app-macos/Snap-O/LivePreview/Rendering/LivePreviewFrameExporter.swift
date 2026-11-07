import AppKit
import CoreImage

@MainActor
final class LivePreviewFrameExporter {
  struct Frame {
    let url: URL
    let image: NSImage
  }

  private enum ExportError: LocalizedError {
    case imageUnavailable

    var errorDescription: String? {
      switch self {
      case .imageUnavailable:
        "Could not create a PNG from the current live preview frame."
      }
    }
  }

  private static let imageContext = CIContext()
  private let encode: @MainActor (CVPixelBuffer) throws -> (image: NSImage, data: Data)

  init(encode: @escaping @MainActor (CVPixelBuffer) throws -> (image: NSImage, data: Data) = LivePreviewFrameExporter.encodePNG) {
    self.encode = encode
  }

  private static func encodePNG(_ pixelBuffer: CVPixelBuffer) throws -> (image: NSImage, data: Data) {
    let source = CIImage(cvPixelBuffer: pixelBuffer)
    guard let image = imageContext.createCGImage(source, from: source.extent),
          let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
      throw ExportError.imageUnavailable
    }
    return (NSImage(cgImage: image, size: .zero), data)
  }

  func export(_ pixelBuffer: CVPixelBuffer, device: Device, to fileStore: FileStore) throws -> Frame {
    try fileStore.withExport {
      let capturedAt = Date()
      let encoded = try encode(pixelBuffer)
      let url = try fileStore.makeUniqueDragDestination(capturedAt: capturedAt, kind: .image)
      try encoded.data.write(to: url, options: .atomic)
      let frame = Frame(url: url, image: encoded.image)
      fileStore.recordExportedFrame(CaptureMedia(device: device, media: .image(
        url: url, capturedAt: capturedAt, display: DisplayInfo(size: frame.image.size, densityScale: nil)
      )))
      return frame
    }
  }
}
