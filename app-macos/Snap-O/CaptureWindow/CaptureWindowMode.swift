import Foundation

@MainActor
enum CaptureWindowMode {
  case idle
  case preparingScreenshot(PreparingScreenshotMode)
  case livePreview(LivePreviewMode)
  case displaying(MediaDisplayMode)
  case error(message: String)
}
