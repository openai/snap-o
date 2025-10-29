import SwiftUI

struct CaptureWindow: View {
  @Environment(\.openWindow)
  private var openWindow

  @StateObject private var controller = CaptureWindowController()
  @StateObject private var settings = AppSettings.shared
  @State private var hasRestoredNetworkInspector = false

  var body: some View {
    ZStack {
      Color.black.ignoresSafeArea()

      if controller.currentCapture != nil {
        CaptureSnapshotView(
          controller: controller.snapshotController,
          livePreviewHost: controller
        )
      } else if controller.isDeviceListInitialized {
        IdleOverlayView(
          hasDevices: controller.hasDevices,
          isDeviceListInitialized: controller.isDeviceListInitialized,
          isProcessing: controller.isProcessing,
          isRecording: controller.isRecording,
          stopRecording: { Task { await controller.stopRecording() } },
          lastError: controller.lastError
        )
      } else {
        WaitingForDeviceView(isDeviceListInitialized: controller.isDeviceListInitialized)
      }
    }
    .task { await controller.start() }
    .onAppear {
      guard !hasRestoredNetworkInspector else { return }
      hasRestoredNetworkInspector = true
      if settings.shouldReopenNetworkInspector {
        openWindow(id: NetworkInspectorWindowID.main)
      }
    }
    .onDisappear { controller.tearDown() }
    .focusedSceneObject(controller)
    .navigationTitle(controller.navigationTitle)
    .background(
      WindowSizingController(displayInfo: controller.displayInfoForSizing)
        .frame(width: 0, height: 0)
    )
    .background(
      WindowLevelController(
        shouldFloat: controller.isRecording || controller.isLivePreviewActive
      )
      .frame(width: 0, height: 0)
    )
    .toolbar {
      CaptureToolbar(controller: controller, settings: settings)

      if let progress = controller.captureProgressText {
        ToolbarItem(placement: .status) {
          Text(progress)
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .background(
              Capsule()
                .fill(.ultraThinMaterial)
                .padding(.horizontal, -6)
                .padding(.vertical, -4)
            )
            .onHover { controller.setProgressHovering($0) }
        }
      }
    }
  }
}
