@preconcurrency import AVFoundation
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum CaptureCropExporter {
  static func save(_ capture: CaptureMedia, crop: CGRect, trim: CaptureTrimRange? = nil, to destination: URL) async throws {
    let staging = destination.deletingLastPathComponent()
      .appendingPathComponent(".\(UUID().uuidString).\(destination.pathExtension)")
    defer { try? FileManager.default.removeItem(at: staging) }
    _ = try await export(capture, crop: crop, trim: trim, to: staging)
    try replaceDestination(destination, with: staging)
  }

  static func saveImage(at source: URL, crop: CGRect, to destination: URL) throws {
    let staging = destination.deletingLastPathComponent()
      .appendingPathComponent(".\(UUID().uuidString).png")
    defer { try? FileManager.default.removeItem(at: staging) }
    _ = try exportImage(at: source, crop: crop, to: staging)
    try replaceDestination(destination, with: staging)
  }

  private static func replaceDestination(_ destination: URL, with staging: URL) throws {
    if FileManager.default.fileExists(atPath: destination.path) {
      _ = try FileManager.default.replaceItemAt(destination, withItemAt: staging)
    } else {
      try FileManager.default.moveItem(at: staging, to: destination)
    }
  }

  static func pixelRect(_ crop: CGRect, size: CGSize, alignment: CGFloat = 1) -> CGRect {
    let rect = CaptureCropGeometry.frame(for: crop, in: CGRect(origin: .zero, size: size))
    let left = max(0, floor(rect.minX / alignment) * alignment)
    let top = max(0, floor(rect.minY / alignment) * alignment)
    let right = min(floor(size.width / alignment) * alignment, ceil(rect.maxX / alignment) * alignment)
    let bottom = min(floor(size.height / alignment) * alignment, ceil(rect.maxY / alignment) * alignment)
    return CGRect(x: left, y: top, width: right - left, height: bottom - top)
  }

  static func image(at url: URL, crop: CGRect) throws -> CGImage {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
          let result = image.cropping(to: pixelRect(crop, size: CGSize(width: image.width, height: image.height))) else {
      throw CocoaError(.fileReadCorruptFile)
    }
    return result
  }

  static func exportImage(at source: URL, crop: CGRect, to destination: URL) throws -> CGSize {
    let image = try image(at: source, crop: crop)
    guard let writer = CGImageDestinationCreateWithURL(destination as CFURL, UTType.png.identifier as CFString, 1, nil) else {
      throw CocoaError(.fileWriteUnknown)
    }
    CGImageDestinationAddImage(writer, image, nil)
    guard CGImageDestinationFinalize(writer) else { throw CocoaError(.fileWriteUnknown) }
    return CGSize(width: image.width, height: image.height)
  }

  static func export(
    _ capture: CaptureMedia,
    crop: CGRect,
    trim: CaptureTrimRange? = nil,
    to destination: URL
  ) async throws -> CaptureMedia {
    guard let source = capture.media.url else { throw CocoaError(.fileReadUnsupportedScheme) }
    guard !FileManager.default.fileExists(atPath: destination.path) else {
      throw CocoaError(.fileWriteFileExists)
    }
    let size: CGSize
    do {
      if crop == CaptureCropGeometry.fullImage, trim == nil {
        try FileManager.default.copyItem(at: source, to: destination)
        size = capture.media.size
      } else if capture.media.isImage {
        size = try exportImage(at: source, crop: crop, to: destination)
      } else {
        size = try await exportVideo(at: source, crop: crop, trim: trim, to: destination)
      }
    } catch {
      try? FileManager.default.removeItem(at: destination)
      throw error
    }
    let data = MediaCommon(
      capturedAt: capture.media.capturedAt,
      display: DisplayInfo(size: size, densityScale: capture.media.densityScale)
    )
    return CaptureMedia(
      id: capture.id,
      device: capture.device,
      media: capture.media.isImage ? .image(url: destination, data: data) : .video(url: destination, data: data)
    )
  }

  private static func exportVideo(at source: URL, crop: CGRect, trim: CaptureTrimRange? = nil, to destination: URL) async throws -> CGSize {
    let asset = AVURLAsset(url: source)
    guard let track = try await asset.loadTracks(withMediaType: .video).first,
          let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
      throw CocoaError(.fileReadCorruptFile)
    }
    let naturalSize = try await track.load(.naturalSize)
    let transform = try await track.load(.preferredTransform)
    let oriented = CGRect(origin: .zero, size: naturalSize).applying(transform)
    let rect = pixelRect(crop, size: oriented.size, alignment: 2)
    let duration = try await asset.load(.duration)
    if let trim {
      guard trim.isValid(for: duration.seconds) else { throw CocoaError(.validationMissingMandatoryProperty) }
      exporter.timeRange = CMTimeRange(
        start: CMTime(seconds: trim.start, preferredTimescale: 60000),
        end: CMTime(seconds: trim.end, preferredTimescale: 60000)
      )
    }
    if crop == CaptureCropGeometry.fullImage {
      try await exporter.export(to: destination, as: .mp4)
      return oriented.size
    }
    var layer = AVVideoCompositionLayerInstruction.Configuration(assetTrack: track)
    layer.setTransform(transform.concatenating(CGAffineTransform(
      translationX: -oriented.minX - rect.minX, y: -oriented.minY - rect.minY
    )), at: .zero)
    let instruction = AVVideoCompositionInstruction(configuration: .init(
      layerInstructions: [AVVideoCompositionLayerInstruction(configuration: layer)],
      timeRange: CMTimeRange(start: .zero, duration: duration)
    ))
    var configuration = try await AVVideoComposition.Configuration(for: asset)
    configuration.renderSize = rect.size
    configuration.instructions = [instruction]
    exporter.videoComposition = AVVideoComposition(configuration: configuration)
    try await exporter.export(to: destination, as: .mp4)
    return rect.size
  }
}
