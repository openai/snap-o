@preconcurrency import AVFoundation
import CoreImage
import ImageIO
import Observation

@Observable
@MainActor
final class LivePreviewThumbnail {
  private static let imageContext = CIContext(options: [.cacheIntermediates: false])

  private(set) var image: CGImage?
  private(set) var isLoading = false
  private(set) var hasFailed = false
  @ObservationIgnored weak var videoRenderer: AVSampleBufferVideoRenderer?
  @ObservationIgnored var pixelSize = CGSize(width: 160, height: 160)
  @ObservationIgnored private var requestID: UUID?

  func cacheLiveFrame() {
    guard let pixelBuffer = videoRenderer?.displayedPixelBuffer() else { return }
    let source = CIImage(cvPixelBuffer: pixelBuffer)
    let scale = min(1, max(pixelSize.width / source.extent.width, pixelSize.height / source.extent.height))
    let scaled = source.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    guard let image = Self.imageContext.createCGImage(scaled, from: scaled.extent) else { return }
    // A screenshot requested before selection must not replace the newer live frame.
    requestID = nil
    isLoading = false
    hasFailed = false
    self.image = image
  }

  func refresh(pixelSize: CGSize, load: () async throws -> Data) async {
    self.pixelSize = pixelSize
    let id = UUID()
    requestID = id
    isLoading = true
    hasFailed = false
    defer {
      if requestID == id { isLoading = false }
    }

    do {
      try Task.checkCancellation()
      let data = try await load()
      try Task.checkCancellation()
      let image = await Task.detached(priority: .utility) {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil as CGImage? }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = (properties?[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue ?? 1
        let height = (properties?[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue ?? 1
        let orientation = (properties?[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        let aspect = (5 ... 8).contains(orientation) ? height / max(width, 1) : width / max(height, 1)
        let pixelHeight = max(pixelSize.height, pixelSize.width / max(aspect, 0.01))
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
          kCGImageSourceCreateThumbnailFromImageAlways: true,
          kCGImageSourceCreateThumbnailWithTransform: true,
          kCGImageSourceThumbnailMaxPixelSize: Int(ceil(pixelHeight * max(aspect, 1))),
          kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary)
      }.value
      guard !Task.isCancelled, requestID == id else { return }
      if let image {
        self.image = image
      } else {
        hasFailed = true
      }
    } catch {
      guard !Task.isCancelled, requestID == id else { return }
      hasFailed = true
    }
  }
}
