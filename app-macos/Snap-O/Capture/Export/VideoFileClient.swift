@preconcurrency import AVFoundation
import Dependencies
import Foundation

struct VideoFileInfo {
  var duration: Double
  var isPlayable: Bool = true
  var size: CGSize
  var transform: CGAffineTransform = .identity
  var frameRate: Double = 30

  var displayedSize: CGSize {
    let bounds = CGRect(origin: .zero, size: size).applying(transform)
    return bounds.size
  }
}

struct VideoExportSettings {
  let size: CGSize
  let transform: CGAffineTransform
  let appliesCrop: Bool
  let timeRange: CMTimeRange?

  init(info: VideoFileInfo, crop: CGRect, timeRange: CMTimeRange?) {
    appliesCrop = crop != CGRect(x: 0, y: 0, width: 1, height: 1)
    let bounds = CGRect(origin: .zero, size: info.size).applying(info.transform)
    let rect = Self.pixelRect(crop, size: bounds.size, alignment: 2)
    size = appliesCrop ? rect.size : bounds.size
    transform = info.transform.concatenating(CGAffineTransform(
      translationX: -bounds.minX - rect.minX, y: -bounds.minY - rect.minY
    ))
    self.timeRange = timeRange
  }

  static func pixelRect(_ crop: CGRect, size: CGSize, alignment: CGFloat = 1) -> CGRect {
    let rect = CGRect(
      x: crop.minX * size.width,
      y: crop.minY * size.height,
      width: crop.width * size.width,
      height: crop.height * size.height
    )
    let left = max(0, floor(rect.minX / alignment) * alignment)
    let top = max(0, floor(rect.minY / alignment) * alignment)
    let right = min(floor(size.width / alignment) * alignment, ceil(rect.maxX / alignment) * alignment)
    let bottom = min(floor(size.height / alignment) * alignment, ceil(rect.maxY / alignment) * alignment)
    return CGRect(x: left, y: top, width: right - left, height: bottom - top)
  }
}

/// The file operations that require macOS media services.
struct VideoFileClient {
  var inspect: @Sendable (URL) async throws -> VideoFileInfo
  var export: @Sendable (URL, VideoExportSettings, URL) async throws -> Void
  var thumbnail: @Sendable (URL, CGSize) async throws -> CGImage
}

extension VideoFileClient: DependencyKey {
  static let liveValue = Self(
    inspect: { url in
      let asset = AVURLAsset(url: url)
      guard let track = try await asset.loadTracks(withMediaType: .video).first else {
        throw CocoaError(.fileReadCorruptFile)
      }
      let (duration, playable) = try await asset.load(.duration, .isPlayable)
      let (size, transform, rate) = try await track.load(.naturalSize, .preferredTransform, .nominalFrameRate)
      return VideoFileInfo(
        duration: duration.seconds,
        isPlayable: playable,
        size: size,
        transform: transform,
        frameRate: Double(rate)
      )
    },
    export: { source, settings, destination in
      let asset = AVURLAsset(url: source)
      guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
        throw CocoaError(.fileReadCorruptFile)
      }
      if let range = settings.timeRange { exporter.timeRange = range }
      if settings.appliesCrop {
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
          throw CocoaError(.fileReadCorruptFile)
        }
        var layer = AVVideoCompositionLayerInstruction.Configuration(assetTrack: track)
        layer.setTransform(settings.transform, at: .zero)
        let duration = try await asset.load(.duration)
        let instruction = AVVideoCompositionInstruction(configuration: .init(
          layerInstructions: [AVVideoCompositionLayerInstruction(configuration: layer)],
          timeRange: CMTimeRange(start: .zero, duration: duration)
        ))
        var configuration = try await AVVideoComposition.Configuration(for: asset)
        configuration.renderSize = settings.size
        configuration.instructions = [instruction]
        exporter.videoComposition = AVVideoComposition(configuration: configuration)
      }
      try await exporter.export(to: destination, as: .mp4)
    },
    thumbnail: { url, size in
      let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
      generator.appliesPreferredTrackTransform = true
      generator.maximumSize = size
      return try await generator.image(at: .zero).image
    }
  )

  static let testValue = Self(
    inspect: unimplemented("VideoFileClient.inspect"),
    export: unimplemented("VideoFileClient.export"),
    thumbnail: unimplemented("VideoFileClient.thumbnail")
  )
}

extension DependencyValues {
  var videoFiles: VideoFileClient {
    get { self[VideoFileClient.self] }
    set { self[VideoFileClient.self] = newValue }
  }
}
