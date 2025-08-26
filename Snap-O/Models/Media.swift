import Foundation

struct Media: Equatable, Sendable {
  let kind: MediaKind
  let url: URL
  let capturedAt: Date
  let width: CGFloat
  let height: CGFloat
  let densityScale: CGFloat?

  var aspectRatio: CGFloat {
    width / height
  }

  static func == (lhs: Media, rhs: Media) -> Bool {
    lhs.kind == rhs.kind &&
      lhs.url == rhs.url &&
      lhs.capturedAt == rhs.capturedAt &&
      lhs.width == rhs.width &&
      lhs.height == rhs.height &&
      lhs.densityScale == rhs.densityScale
  }
}

enum MediaKind {
  case image
  case video
}
