import SwiftUI

struct CaptureWindow: View {
  @StateObject private var deviceSelectionController = CaptureDeviceSelectionController()

  var body: some View {
    ZStack {
      Color.black.ignoresSafeArea()

      if let deviceID = deviceSelectionController.devices.selectedID {
        CaptureDeviceView(
          deviceID: deviceID,
          deviceSelectionController: deviceSelectionController
        )
        .id(deviceID)
      } else {
        WaitingForDeviceView(isDeviceListInitialized: deviceSelectionController.isDeviceListInitialized)
      }
    }
    .task { await deviceSelectionController.start() }
    .focusedSceneObject(deviceSelectionController)
    .toolbar {
      TitleDevicePickerToolbar(deviceSelection: deviceSelectionController)
    }
    .background(
      WindowTitleVisibilityController()
        .frame(width: 0, height: 0)
    )
  }
}

private struct CaptureDeviceView: View {
  let deviceID: String
  @ObservedObject var deviceSelectionController: CaptureDeviceSelectionController

  @StateObject private var controller: CaptureController

  init(deviceID: String, deviceSelectionController: CaptureDeviceSelectionController) {
    self.deviceID = deviceID
    self.deviceSelectionController = deviceSelectionController
    _controller = StateObject(
      wrappedValue: CaptureController(
        deviceID: deviceID
      )
    )
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
      WindowSizingController(currentMedia: controller.currentMedia)
        .frame(width: 0, height: 0)
    )
    .onOpenURL { controller.handle(url: $0) }
    .focusedSceneObject(controller)
    .toolbar {
      CaptureToolbar(controller: controller)
    }
    .onAppear {
      deviceSelectionController.updateShouldPreserveSelection(controller.currentMedia != nil)
    }
    .onChange(of: controller.currentMedia) { _ in
      deviceSelectionController.updateShouldPreserveSelection(controller.currentMedia != nil)
    }
    .onDisappear {
      Task { await controller.prepareForDismissal() }
      deviceSelectionController.updateShouldPreserveSelection(false)
    }
    .onChange(of: controller.deviceUnavailableSignal) {
      deviceSelectionController.handleDeviceUnavailable(currentDeviceID: deviceID)
    }
  }
}

private struct WaitingForDeviceView: View {
  let isDeviceListInitialized: Bool

  var body: some View {
    VStack(spacing: 12) {
      Image("Aperture")
        .resizable()
        .frame(width: 64, height: 64)
        .infiniteRotate(animated: true)

      if !isDeviceListInitialized {
        HStack(spacing: 8) {
          ProgressView()
            .controlSize(.small)
          Text("Loading devices…")
            .foregroundStyle(.secondary)
        }
        .transition(.opacity)
      } else {
        Text("Waiting for device…")
          .foregroundStyle(.gray)
          .transition(.opacity)
      }
    }
  }
}
