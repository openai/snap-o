import Combine
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
    .onDisappear { controller.tearDown() }
    .onReceive(NotificationCenter.default.publisher(for: .snapoCommandRequested)) { notification in
      guard let command = notification.object as? SnapOCommand else { return }
      Task { await handle(command, controller: controller) }
    }
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
            .onChange(of: isCaptureInFlight) {
              guard isCaptureInFlight else { return }
              controller.setProgressHovering(false)
            }
        }
      }
    }
  }

  private func handle(_ command: SnapOCommand, controller: CaptureWindowController) async {
    switch command {
    case .record:
      guard controller.canStartRecordingNow else { return }
      await controller.startRecording()
    case .capture:
      guard controller.canCaptureNow else { return }
      await controller.captureScreenshots()
    case .livepreview:
      guard controller.canStartLivePreviewNow else { return }
      await controller.startLivePreview()
    }
  }
}
