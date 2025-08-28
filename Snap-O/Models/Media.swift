import Foundation
import CoreGraphics
import ImageIO
@preconcurrency import AVFoundation

enum Media: Equatable, Sendable {
  case image(url: URL, data: MediaCommon)
  case video(url: URL, data: MediaCommon)
  case livePreview(data: MediaCommon)
}

struct MediaCommon: Equatable, Sendable {
  var capturedAt: Date
  var size: CGSize
  var densityScale: CGFloat?
  var aspectRatio: CGFloat { size.width / size.height }
}

// MARK: - Conveniences
extension Media {
  var common: MediaCommon {
    switch self {
    case .image(_, let d), .video(_, let d), .livePreview(let d): d
    }
  }
  var url: URL? {
    switch self {
    case .image(let u, _), .video(let u, _): u
    case .livePreview: nil
    }
  }
  var isImage: Bool { if case .image = self { true } else { false } }
  var isVideo: Bool { if case .video = self { true } else { false } }
  var isLivePreview: Bool { if case .livePreview = self { true } else { false } }
  var aspectRatio: CGFloat { common.aspectRatio }
  var size: CGSize { common.size }
  var capturedAt: Date { common.capturedAt }
  var densityScale: CGFloat? { common.densityScale }
  var saveKind: MediaSaveKind? {
    switch self {
    case .image: .image
    case .video: .video
    case .livePreview: nil
    }
  }
}

enum MediaSaveKind {
  case image
  case video
}

extension MediaSaveKind {
  var fileExtension: String {
    switch self {
    case .image: "png"
    case .video: "mp4"
    }
  }
}

// MARK: - Factories
extension Media {
  static func image(
    url: URL,
    capturedAt: Date,
    size: CGSize,
    densityScale: CGFloat?
  ) -> Media {
    .image(
      url: url,
      data: MediaCommon(capturedAt: capturedAt, size: size, densityScale: densityScale)
    )
  }

  static func video(
    url: URL,
    capturedAt: Date,
    size: CGSize,
    densityScale: CGFloat?
  ) -> Media {
    .video(
      url: url,
      data: MediaCommon(capturedAt: capturedAt, size: size, densityScale: densityScale)
    )
  }

  static func livePreview(
    capturedAt: Date,
    size: CGSize,
    densityScale: CGFloat?
  ) -> Media {
    .livePreview(
      data: MediaCommon(capturedAt: capturedAt, size: size, densityScale: densityScale)
    )
  }
}

func pngSize(from data: Data) throws -> CGSize {
  guard let source = CGImageSourceCreateWithData(data as CFData, nil),
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
        let width = properties[kCGImagePropertyPixelWidth] as? Int,
        let height = properties[kCGImagePropertyPixelHeight] as? Int
  else {
    throw CocoaError(.fileReadCorruptFile)
  }
  return CGSize(width: CGFloat(width), height: CGFloat(height))
}

extension Media {
  static func video(
    from asset: AVURLAsset,
    url: URL,
    capturedAt: Date,
    densityProvider: @escaping @Sendable () async -> CGFloat?
  ) async throws -> Media? {
    async let densityTask = densityProvider()
    let tracks = try await asset.load(.tracks)
    guard let videoTrack = tracks.first(where: { $0.mediaType == .video }) else {
      _ = await densityTask
      return nil
    }

    async let naturalSizeTask = videoTrack.load(.naturalSize)
    async let transformTask = videoTrack.load(.preferredTransform)
    let (naturalSize, transform) = try await (naturalSizeTask, transformTask)
    let density = await densityTask
    let applied = naturalSize.applying(transform)
    let size = CGSize(width: abs(applied.width), height: abs(applied.height))

    return Media.video(
      url: url,
      capturedAt: capturedAt,
      size: size,
      densityScale: density
    )
  }
}
