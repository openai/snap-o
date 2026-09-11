import Foundation

@MainActor
enum CaptureWindowMode {
  case idle
  case preparingScreenshot(PreparingScreenshotMode)
  case recording(RecordingMode)
  case livePreview(LivePreviewMode)
  case displaying(MediaDisplayMode)
  case error(message: String)
}
