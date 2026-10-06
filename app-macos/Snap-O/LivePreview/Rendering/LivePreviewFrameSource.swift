@preconcurrency import AVFoundation
import Foundation

/// A source supplies display-ready samples and owns its transport until stopped.
@MainActor
protocol LivePreviewFrameSource: AnyObject {
  var hasIndependentFrames: Bool { get }
  func requestKeyFrame()
  func start(deliver: @escaping @MainActor @Sendable (LivePreviewFrameEvent) -> Void)
  /// Requests cancellation without blocking event delivery.
  func stop()
  /// Joins source cleanup after stop, including a late connection from startup.
  func waitUntilStopped() async
}

extension LivePreviewFrameSource {
  /// Independent-frame sources do not need a new keyframe for a joining renderer.
  func requestKeyFrame() {}
}

/// Samples are transferred to the main actor and never mutated after delivery.
enum LivePreviewFrameEvent: @unchecked Sendable {
  case density(CGFloat)
  case format(CMVideoFormatDescription)
  case sample(CMSampleBuffer, isKeyFrame: Bool)
  case stopped(Error?)
}
