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
    .overlay(alignment: .top) {
      if controller.previews.count > 1, controller.hint.isVisible {
        LiveDevicePreviewStrip(
          previews: controller.previews, selectedDeviceID: controller.selectedPreviewDeviceID,
          attachment: controller.currentPreview.flatMap { controller.livePreviewAttachment(for: $0.device.id) },
          loadSnapshot: controller.livePreviewScreenshot, selectDevice: controller.selectDevice
        )
        .padding(.top, 12)
        .onHover { controller.hint.setHovered($0) }
        .transition(.offset(CGSize(width: 0, height: -15)).combined(with: .opacity))
      }
    }
    .animation(.easeInOut(duration: 0.3), value: controller.hint.isVisible)
  }
}
