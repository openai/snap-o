import Foundation

@MainActor
struct CaptureServices {
  let livePreview: LivePreviewService
  let startup: StartupCapturePreparation
  let screenshots: @MainActor (Device) -> ScreenshotCapture
  let recording: @MainActor (Device, RecordingOptions) -> RecordingCapture
  let makeEmulatorControls: @MainActor (DeviceTarget) -> EmulatorControlsController?

  init(
    livePreview: LivePreviewService,
    screenshots: @escaping @MainActor (Device) -> ScreenshotCapture,
    recording: @escaping @MainActor (Device, RecordingOptions) -> RecordingCapture,
    makeEmulatorControls: @escaping @MainActor (DeviceTarget) -> EmulatorControlsController? = { _ in nil }
  ) {
    self.livePreview = livePreview
    self.screenshots = screenshots
    self.recording = recording
    self.makeEmulatorControls = makeEmulatorControls
    startup = StartupCapturePreparation(
      screenshots: screenshots, livePreview: livePreview, makeEmulatorControls: makeEmulatorControls
    )
  }
}
