@preconcurrency import AVFoundation
import Foundation

/// A source supplies display-ready samples and owns its transport until stopped.
@MainActor
protocol LivePreviewFrameSource: AnyObject {
  var hasIndependentFrames: Bool { get }
  func setFrameSize(_ size: LivePreviewFrameSize)
  func requestKeyFrame()
  func start(deliver: @escaping @MainActor @Sendable (LivePreviewFrameEvent) -> Void)
  /// Requests cancellation without blocking event delivery.
  func stop()
  /// Joins source cleanup after stop, including a late connection from startup.
  func waitUntilStopped() async
}

extension LivePreviewFrameSource {
  func setFrameSize(_ size: LivePreviewFrameSize) {}

  /// Independent-frame sources do not need a new keyframe for a joining renderer.
  func requestKeyFrame() {}
}

/// Samples are transferred to the main actor and never mutated after delivery.
enum LivePreviewFrameEvent: @unchecked Sendable {
  case density(CGFloat)
  case format(CMVideoFormatDescription, displaySize: CGSize? = nil)
  case sample(CMSampleBuffer, isKeyFrame: Bool)
  case stopped(Error?)
}

/// Native resolution is required by recorders; inactive previews do not set a size.
enum LivePreviewFrameSize: Equatable {
  case native
  case preview(CGSize)
  case inactive

  static func previewSize(_ pixels: CGSize?) -> Self {
    guard let pixels, pixels.width.isFinite, pixels.height.isFinite,
          pixels.width > 0, pixels.height > 0 else { return .inactive }
    return .preview(CGSize(width: min(8192, ceil(pixels.width)), height: min(8192, ceil(pixels.height))))
  }

  static func maximum(_ sizes: some Sequence<Self>) -> Self {
    var maximum = CGSize.zero
    for size in sizes {
      switch size {
      case .native: return .native
      case .preview(let pixels):
        maximum.width = max(maximum.width, pixels.width)
        maximum.height = max(maximum.height, pixels.height)
      case .inactive: break
      }
    }
    return previewSize(maximum)
  }
}
