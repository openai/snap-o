import Foundation

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
