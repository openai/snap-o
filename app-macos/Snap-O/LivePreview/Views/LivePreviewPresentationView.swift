import SwiftUI

struct LivePreviewPresentationView: View {
  @Bindable var controller: CapturePaneSession

  var body: some View {
    ZStack {
      if let preview = controller.currentPreview {
        LiveCaptureView(
          device: preview.device, attachment: controller.livePreviewAttachment(for: preview.device.id),
          fileStore: controller.fileStore
        )
        .id(preview.id)
      }
    }
  }
}
