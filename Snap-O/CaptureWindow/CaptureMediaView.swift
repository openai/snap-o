import SwiftUI

struct CaptureMediaView: View {
  @ObservedObject var controller: CaptureWindowController

  private var isCurrentSelection: Bool {
    controller.selectedMediaID == capture?.id
  }

  private var displayInfo: DisplayInfo? {
    controller.currentCapture?.media.common.display
  }

  var body: some View {
    ZStack {
      if let capture = controller.currentCapture {
        MediaDisplayView(
          media: capture.media,
          makeTempDragFile: { controller.makeTempDragFile(kind: $0) },
          livePreviewRenderer: capture.media.isLivePreview ? controller.livePreviewRenderer(for: capture.device.id) : nil
        )
        .transition(.opacity)
      } else {
        IdleOverlayView(controller: controller)
          .transition(.opacity)
      }
    }
    .zIndex(isCurrentSelection ? 1 : 2)
    .animation(.snappy(duration: 0.15), value: controller.currentCapture?.media.url)
    .background(
      WindowSizingController(displayInfo: displayInfo)
        .frame(width: 0, height: 0)
    )
    .background(
      WindowLevelController(shouldFloat: controller.isRecording)
        .frame(width: 0, height: 0)
    )
  }
}
