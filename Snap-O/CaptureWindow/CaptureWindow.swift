import SwiftUI

struct CaptureWindow: View {
  let services: AppServices

  @State private var controller: CaptureController
  @State private var windowTitle: String = "Snap-O"

  init(services: AppServices) {
    self.services = services
    _controller = State(initialValue: CaptureController(services: services))
  }

  private var deviceStore: DeviceStore { services.deviceService.store }

  var body: some View {
    ZStack {
      Color.black.ignoresSafeArea()

      if let media = controller.currentMedia {
        MediaDisplayView(media: media, controller: controller)
          .transition(
            media.isLivePreview
              ? AnyTransition.opacity
              : AnyTransition.scale(scale: 0.8).combined(with: .opacity)
          )
      } else {
        IdleOverlayView(controller: controller, hasDevices: !controller.devices.available.isEmpty)
      }
    }
    .animation(.snappy(duration: 0.25), value: controller.currentMedia != nil)
    .background(
      WindowSizingController(currentMedia: controller.currentMedia)
        .frame(width: 0, height: 0)
    )
    .onOpenURL { controller.handle(url: $0) }
    .onAppear { controller.onDevicesChanged(deviceStore.devices) }
    .onChange(of: deviceStore.devices) { _, devices in
      controller.onDevicesChanged(devices)
      updateTitle(controller.devices.currentDevice)
    }
    .onChange(of: controller.devices.selectedID) { _, newID in
      updateTitle(controller.devices.currentDevice)
      if let id = newID {
        Task { await controller.refreshPreview(for: id) }
      }
    }
    .onChange(of: controller.showTouchesDuringCapture) { _, newValue in
      Task { await controller.applyShowTouchesSetting(newValue) }
    }
    .task {
      updateTitle(controller.devices.currentDevice)
      if let id = controller.devices.selectedID {
        await controller.refreshPreview(for: id)
      }
    }
    .navigationTitle(windowTitle)
    .focusedSceneValue(\.captureController, controller)
    .toolbar { CaptureToolbar(controller: controller) }
  }

  private func updateTitle(_ device: Device?) {
    windowTitle = device?.readableTitle ?? "Snap-O"
  }
}
