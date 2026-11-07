@preconcurrency import AVFoundation
import CoreImage
import ImageIO
import Observation

@Observable
@MainActor
final class LivePreviewThumbnail {
  private let snapshotImage: @Sendable (Data, CGSize) async -> CGImage?
  private let frameImage: @MainActor (CVPixelBuffer, CGSize) -> CGImage?

  init(
    snapshotImage: @escaping @Sendable (Data, CGSize) async -> CGImage? = LivePreviewThumbnail.renderSnapshot,
    frameImage: @escaping @MainActor (CVPixelBuffer, CGSize) -> CGImage? = LivePreviewThumbnail.renderFrame
  ) {
    self.snapshotImage = snapshotImage
    self.frameImage = frameImage
  }

  private static let imageContext = CIContext(options: [.cacheIntermediates: false])

  private(set) var image: CGImage?
  private(set) var isLoading = false
  private(set) var hasFailed = false
  @ObservationIgnored weak var videoRenderer: AVSampleBufferVideoRenderer?
  @ObservationIgnored var pixelSize = CGSize(width: 160, height: 160)
  @ObservationIgnored private var requestID: UUID?

  func cacheLiveFrame() {
    guard let pixelBuffer = videoRenderer?.displayedPixelBuffer() else { return }
    cacheLiveFrame(pixelBuffer)
  }

  func cacheLiveFrame(_ pixelBuffer: CVPixelBuffer) {
    guard let image = frameImage(pixelBuffer, pixelSize) else { return }
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
      let image = await snapshotImage(data, pixelSize)
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

  nonisolated static func snapshotPixelLimit(source: CGSize, orientation: Int, target: CGSize) -> Int {
    let aspect = (5 ... 8).contains(orientation) ? source.height / max(source.width, 1) : source.width / max(source.height, 1)
    let pixelHeight = max(target.height, target.width / max(aspect, 0.01))
    return Int(ceil(pixelHeight * max(aspect, 1)))
  }

  nonisolated static func frameScale(source: CGSize, target: CGSize) -> CGFloat {
    min(1, max(target.width / source.width, target.height / source.height))
  }

  private static func renderFrame(_ pixelBuffer: CVPixelBuffer, _ pixelSize: CGSize) -> CGImage? {
    let source = CIImage(cvPixelBuffer: pixelBuffer)
    let scale = frameScale(source: source.extent.size, target: pixelSize)
    let scaled = source.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    return imageContext.createCGImage(scaled, from: scaled.extent)
  }

  private nonisolated static func renderSnapshot(_ data: Data, _ pixelSize: CGSize) async -> CGImage? {
    await Task.detached(priority: .utility) {
      guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil as CGImage? }
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
      let width = (properties?[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue ?? 1
      let height = (properties?[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue ?? 1
      let orientation = (properties?[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
      return CGImageSourceCreateThumbnailAtIndex(source, 0, [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: snapshotPixelLimit(
          source: CGSize(width: width, height: height), orientation: orientation, target: pixelSize
        ),
        kCGImageSourceShouldCacheImmediately: true
      ] as CFDictionary)
    }.value
  }
}

@MainActor
final class LivePreviewThumbnailRefresh {
  private var didCheckInitialThumbnail = false

  func run(
    thumbnail: LivePreviewThumbnail,
    isSelected: Bool,
    pixelSize: CGSize,
    capture: () async throws -> Data
  ) async {
    thumbnail.pixelSize = pixelSize
    guard !isSelected, !didCheckInitialThumbnail else { return }
    didCheckInitialThumbnail = true
    await thumbnail.refresh(pixelSize: pixelSize, load: capture)
  }
}
