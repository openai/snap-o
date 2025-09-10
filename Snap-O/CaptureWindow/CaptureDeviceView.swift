import SwiftUI

struct CaptureDeviceView: View {
  let deviceID: String
  @ObservedObject var deviceSelectionController: CaptureDeviceSelectionController

  @StateObject private var controller: CaptureController
  private let dismissalDelayNanoseconds: UInt64 = 300_000_000
  private var isCurrentSelection: Bool {
    deviceSelectionController.devices.selectedID == deviceID
  }

  init(deviceID: String, deviceSelectionController: CaptureDeviceSelectionController) {
    self.deviceID = deviceID
    self.deviceSelectionController = deviceSelectionController
    _controller = StateObject(wrappedValue: CaptureController(deviceID: deviceID))
  }

  var body: some View {
    ZStack {
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
          hasDevices: deviceSelectionController.hasDevices,
          isDeviceListInitialized: deviceSelectionController.isDeviceListInitialized
        )
      }
    }
    .animation(.snappy(duration: 0.15), value: controller.currentMedia != nil)
    .background(
      WindowSizingController(displayInfo: controller.displayInfo)
        .frame(width: 0, height: 0)
    )
    .onOpenURL { controller.handle(url: $0) }
    .focusedSceneObject(controller)
    .toolbar {
      CaptureToolbar(controller: controller)
    }
    .onAppear { handleMediaChange(controller.currentMedia) }
    .onChange(of: controller.currentMedia) { _, newMedia in
      handleMediaChange(newMedia)
    }
    .onChange(of: controller.deviceUnavailableSignal) {
      deviceSelectionController.handleDeviceUnavailable(currentDeviceID: deviceID)
    }
    .zIndex(isCurrentSelection ? 1 : 2)
  }

  private func handleMediaChange(_ media: Media?) {
    let shouldPreserveSelection = media?.isLivePreview == false
    deviceSelectionController.updateShouldPreserveSelection(shouldPreserveSelection)
  }
}
