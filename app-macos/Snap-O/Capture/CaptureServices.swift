struct CaptureServices {
  let coordinator: CaptureCoordinator
  let screenshots: ScreenshotService
  let recording: RecordingService
  let livePreview: LivePreviewService
  let startup: StartupCapturePreparation
}
