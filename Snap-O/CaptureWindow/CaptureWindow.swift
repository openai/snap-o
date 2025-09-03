import SwiftUI

struct CaptureWindow: View {
  @StateObject private var controller = CaptureController()

  var body: some View {
    ZStack {
      Color.black.ignoresSafeArea()

      if let media = controller.currentMedia {
        MediaDisplayView(media: media, controller: controller)
          .transition(
            media.isLivePreview
              ? AnyTransition.opacity
              : AnyTransition.scale(scale: 0.9).combined(with: .opacity)
          )
      } else {
        IdleOverlayView(
          controller: controller,
          hasDevices: !controller.devices.available.isEmpty,
          isDeviceListInitialized: controller.deviceStore.hasReceivedInitialDeviceList
        )
      }
    }
    .animation(.snappy(duration: 0.15), value: controller.currentMedia != nil)
    .background(
      ZStack {
        WindowSizingController(currentMedia: controller.currentMedia)
          .frame(width: 0, height: 0)
        WindowTitleVisibilityController()
          .frame(width: 0, height: 0)
      }
    )
    .onOpenURL { controller.handle(url: $0) }
    .task { await controller.deviceStore.start() }
    .focusedSceneValue(\.captureController, controller)
    .toolbar {
      TitleDevicePickerToolbar(
        controller: controller,
        isDeviceListInitialized: controller.deviceStore.hasReceivedInitialDeviceList
      )
      CaptureToolbar(controller: controller)
    }
  }
}
