@preconcurrency import AVFoundation
import CoreImage
import ImageIO
import Observation
import Synchronization
import VideoToolbox

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

  private nonisolated static let imageContext = CIContext(options: [.cacheIntermediates: false])

  private(set) var image: CGImage?
  private(set) var lastPreviewFrame: CGImage?
  private(set) var lastPreviewFrameHasLightCenter = false
  private(set) var displayedSessionID: UUID?
  private(set) var isLoading = false
  private(set) var hasFailed = false
  @ObservationIgnored weak var videoRenderer: AVSampleBufferVideoRenderer?
  @ObservationIgnored var pixelSize = CGSize(width: 160, height: 160)
  @ObservationIgnored private var requestID: UUID?
  @ObservationIgnored private var pendingStill: Task<Void, Never>?

  func cacheLiveFrame() {
    guard let pixelBuffer = videoRenderer?.displayedPixelBuffer() else { return }
    cacheLiveFrame(pixelBuffer)
  }

  func cacheLiveFrame(_ pixelBuffer: CVPixelBuffer) {
    guard let image = frameImage(pixelBuffer, pixelSize) else { return }
    pendingStill?.cancel()
    storeLiveFrame(image)
  }

  func cacheLastFrames(_ frames: PreviewFrameSnapshot) {
    if let buffer = videoRenderer?.displayedPixelBuffer() ?? frames.samples.last?.imageBuffer {
      cacheLiveFrame(buffer)
      return
    }
    guard !frames.samples.isEmpty else { return }
    pendingStill?.cancel()
    let size = pixelSize
    pendingStill = Task { [weak self] in
      let image = await Task.detached(priority: .utility) { frames.render(at: size) }.value
      guard !Task.isCancelled, let image else { return }
      self?.storeLiveFrame(image)
    }
  }

  private func storeLiveFrame(_ image: CGImage) {
    // A screenshot requested before selection must not replace the newer live frame.
    requestID = nil
    isLoading = false
    hasFailed = false
    self.image = image
    lastPreviewFrame = image
    lastPreviewFrameHasLightCenter = Self.hasLightCenter(image)
  }

  private static func hasLightCenter(_ image: CGImage) -> Bool {
    let side = max(1, min(image.width, image.height) / 8)
    let center = CGRect(x: (image.width - side) / 2, y: (image.height - side) / 2, width: side, height: side)
    guard let sample = image.cropping(to: center), let space = CGColorSpace(name: CGColorSpace.linearGray),
          let context = CGContext(
            data: nil,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 1,
            space: space,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
          ),
          let luminance = context.data?.assumingMemoryBound(to: UInt8.self) else { return false }
    context.interpolationQuality = .high
    context.draw(sample, in: CGRect(x: 0, y: 0, width: 1, height: 1))
    // At about 20% linear luminance, dark blades give more contrast than pale blades.
    return luminance.pointee >= 51
  }

  func didDisplayFrame(in sessionID: UUID) {
    displayedSessionID = sessionID
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

  fileprivate nonisolated static func renderFrame(_ pixelBuffer: CVPixelBuffer, _ pixelSize: CGSize) -> CGImage? {
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

/// Some display layers cannot return their displayed pixels. Decode one bounded group only when detaching.
struct PreviewFrameSnapshot: @unchecked Sendable {
  private(set) var samples: [CMSampleBuffer] = []
  private var byteCount = 0

  mutating func append(_ sample: CMSampleBuffer) {
    if sample.imageBuffer != nil {
      samples = [sample]
      byteCount = 0
      return
    }
    if sample.sampleAttachments.first?[.notSync] as? Bool != true {
      samples.removeAll(keepingCapacity: true)
      byteCount = 0
    } else if samples.isEmpty { return }
    byteCount += CMSampleBufferGetTotalSampleSize(sample)
    guard samples.count < 120, byteCount <= 4 * 1024 * 1024 else {
      samples.removeAll()
      byteCount = 0
      return
    }
    samples.append(sample)
  }

  fileprivate func render(at size: CGSize) -> CGImage? {
    guard let format = samples.first?.formatDescription else { return nil }
    var decoder: VTDecompressionSession?
    guard VTDecompressionSessionCreate(
      allocator: kCFAllocatorDefault, formatDescription: format, decoderSpecification: nil,
      imageBufferAttributes: nil, outputCallback: nil, decompressionSessionOut: &decoder
    ) == noErr, let decoder else { return nil }
    defer { VTDecompressionSessionInvalidate(decoder) }
    let image = Mutex<CGImage?>(nil)
    for (index, sample) in samples.enumerated() {
      let last = index == samples.count - 1
      // With no asynchronous or temporal processing, the output callback completes before this call returns.
      let status = VTDecompressionSessionDecodeFrame(
        decoder, sampleBuffer: sample, flags: last ? [] : [._DoNotOutputFrame], infoFlagsOut: nil
      ) { status, _, buffer, _, _ in
        if last, status == noErr, let buffer {
          image.withLock { $0 = LivePreviewThumbnail.renderFrame(buffer, size) }
        }
      }
      guard status == noErr else { return nil }
    }
    return image.withLock { $0 }
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
