import CoreGraphics

enum CaptureReviewLayout {
  static let edgeSpacing: CGFloat = 16
  static let toolbarHeight: CGFloat = 36
  static let toolbarSpacing: CGFloat = 12
  static let playbackHeight: CGFloat = 28
  static let playbackSpacing: CGFloat = 12

  static func mediaFrame(in size: CGSize, aspectRatio: CGFloat, showsPlayback: Bool = false) -> CGRect {
    let top = toolbarSpacing + toolbarHeight + toolbarSpacing
    let playbackSpace = showsPlayback ? playbackHeight + playbackSpacing : 0
    let available = CGSize(
      width: max(0, size.width - edgeSpacing * 2),
      height: max(0, size.height - top - edgeSpacing - playbackSpace)
    )
    guard aspectRatio.isFinite, aspectRatio > 0 else { return .zero }
    let width = min(available.width, available.height * aspectRatio)
    let height = width / aspectRatio
    return CGRect(
      x: (size.width - width) / 2,
      y: top + (available.height - height) / 2,
      width: width,
      height: height
    )
  }

  static func playbackFrame(in size: CGSize, mediaFrame: CGRect) -> CGRect {
    let width = min(420, max(0, size.width - edgeSpacing * 2))
    return CGRect(x: (size.width - width) / 2, y: mediaFrame.maxY + playbackSpacing, width: width, height: playbackHeight)
  }
}
