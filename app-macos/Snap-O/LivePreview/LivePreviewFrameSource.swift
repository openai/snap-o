@preconcurrency import AVFoundation
import Foundation

/// A source supplies display-ready samples and owns its transport until stopped.
@MainActor
protocol LivePreviewFrameSource: AnyObject {
  var hasIndependentFrames: Bool { get }
  func start(deliver: @escaping @MainActor @Sendable (LivePreviewFrameEvent) -> Void)
  func stop()
}

/// Samples are transferred to the main actor and never mutated after delivery.
enum LivePreviewFrameEvent: @unchecked Sendable {
  case density(CGFloat)
  case format(CMVideoFormatDescription)
  case sample(CMSampleBuffer, isKeyFrame: Bool)
  case stopped(Error?)
}
