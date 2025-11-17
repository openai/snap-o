import Observation
import SwiftUI

private struct CaptureControllerKey: FocusedValueKey {
  typealias Value = CaptureWindowController
}

extension FocusedValues {
  var captureController: CaptureWindowController? {
    get { self[CaptureControllerKey.self] }
    set { self[CaptureControllerKey.self] = newValue }
  }
}

struct CaptureWindow: View {
  @Environment(\.openWindow)
  private var openWindow

  @Environment(AppSettings.self)
  private var settings

  @State private var controller: CaptureWindowController

  init(
    captureService: CaptureService,
    deviceTracker: DeviceTracker,
    fileStore: FileStore,
    adbService: ADBService
  ) {
    _controller = State(
      initialValue: CaptureWindowController(
        captureService: captureService,
        deviceTracker: deviceTracker,
        fileStore: fileStore,
        adbService: adbService
      )
    )
  }

  var body: some View {
    @Bindable var controller = controller
    ZStack {
      Color.black.ignoresSafeArea()

      if controller.currentCapture != nil {
        CaptureSnapshotView(
          controller: controller.snapshotController,
          fileStore: controller.fileStore,
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
      guard !settings.hasRestoredNetworkInspector else { return }
      settings.hasRestoredNetworkInspector = true
      if settings.shouldReopenNetworkInspector {
        openWindow(id: NetworkInspectorWindowID.main)
      }
    }
    .onDisappear { controller.tearDown() }
    .focusedSceneValue(\.captureController, controller)
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
      CaptureToolbar(controller: controller)

      if !controller.isRecording, let progress = controller.captureProgressText {
        let isCaptureInFlight = controller.isProcessing || controller.isRecording

        ToolbarItem(placement: .status) {
          Text(progress)
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .padding(.vertical, 4)
            .padding(.horizontal, 6)
            .background(
              Capsule()
                .fill(.ultraThinMaterial)
            )
            .opacity(isCaptureInFlight ? 0.45 : 1)
            .allowsHitTesting(!isCaptureInFlight)
            .onHover { hovering in
              guard !isCaptureInFlight else {
                if !hovering { controller.setProgressHovering(false) }
                return
              }
              controller.setProgressHovering(hovering)
            }
            .onChange(of: isCaptureInFlight) { disabled in
              guard disabled else { return }
              controller.setProgressHovering(false)
            }
        }
      }
    }
  }
}
