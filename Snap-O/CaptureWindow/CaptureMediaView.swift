import SwiftUI

struct CaptureMediaView: View {
  @ObservedObject var controller: CaptureWindowController

  private var currentCapture: CaptureMedia? { controller.currentCapture }

  private var isCurrentSelection: Bool {
    guard let capture = currentCapture else { return false }
    return controller.selectedMediaID == capture.id
  }

  private var displayInfo: DisplayInfo? {
    currentCapture?.media.common.display
  }

  var body: some View {
    ZStack {
      if let capture = currentCapture {
        switch capture.media {
        case .image(let url, _):
          ImageCaptureView(
            url: url,
            makeTempDragFile: { controller.makeTempDragFile(kind: $0) }
          )
          .transition(.opacity)

        case .video(let url, _):
          VideoCaptureView(
            url: url,
            makeTempDragFile: { controller.makeTempDragFile(kind: $0) }
          )
          .transition(.opacity)

        case .livePreview:
          LiveCaptureView(controller: controller, capture: capture)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .transition(.opacity)
        }
      } else {
        IdleOverlayView(controller: controller)
          .transition(.opacity)
      }
    }
    .zIndex(isCurrentSelection ? 1 : 2)
    .animation(.snappy(duration: 0.15), value: controller.currentCapture?.id)
    .background(
      WindowSizingController(displayInfo: displayInfo)
        .frame(width: 0, height: 0)
    )
    .background(
      WindowLevelController(
        shouldFloat: controller.isRecording || controller.isLivePreviewActive
      )
        .frame(width: 0, height: 0)
    )
  }
}
