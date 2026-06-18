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

      if controller.currentCapture != nil, !controller.screenshotFailures.isEmpty {
        VStack {
          ScreenshotFailureBanner(
            failures: controller.screenshotFailures,
            successfulCaptureCount: controller.mediaList.count,
            onDismiss: controller.dismissScreenshotFailures
          )
          Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
      }
    }
    .task { await controller.start() }
    .onDisappear { controller.tearDown() }
    .onReceive(NotificationCenter.default.publisher(for: .snapoCommandRequested)) { notification in
      guard let command = notification.object as? SnapOCommand else { return }
      Task { await handle(command, controller: controller) }
    }
    .focusedSceneValue(\.captureController, controller)
    .background(
      WindowSizingController(displayInfo: controller.displayInfoForSizing)
        .frame(width: 0, height: 0)
    )
    .background(
      WindowTitleController(title: controller.navigationTitle)
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

        if #available(macOS 26.0, *) {
          ToolbarSpacer(.fixed, placement: .principal)
        } else {
          ToolbarItem(placement: .principal) {
            Spacer()
              .frame(width: 8)
          }
        }

        ToolbarItemGroup(placement: .principal) {
          Text(progress)
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .fixedSize()
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

private struct ScreenshotFailureBanner: View {
  let failures: [CaptureFailure]
  let successfulCaptureCount: Int
  let onDismiss: () -> Void

  private var title: String {
    let total = successfulCaptureCount + failures.count
    if total == 1 { return "Screenshot failed" }
    return "\(failures.count) of \(total) screenshots failed"
  }

  var body: some View {
    HStack(alignment: .top, spacing: 8) {
      Image(systemName: "exclamationmark.triangle.fill")
        .font(.system(size: 14))
        .foregroundStyle(.orange)
        .padding(.top, 1)

      VStack(alignment: .leading, spacing: 3) {
        Text(title)
          .font(.subheadline.weight(.semibold))

        ForEach(failures, id: \.device.id) { failure in
          Text(failure.message)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }

      Spacer(minLength: 0)

      Button(action: onDismiss) {
        Image(systemName: "xmark.circle.fill")
          .font(.system(size: 14))
          .symbolRenderingMode(.hierarchical)
          .frame(width: 18, height: 18)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .foregroundStyle(.secondary)
      .help("Dismiss")
    }
    .padding(12)
    .frame(maxWidth: 460, alignment: .leading)
    .background(
      Color(nsColor: .controlBackgroundColor),
      in: RoundedRectangle(cornerRadius: 8, style: .continuous)
    )
    .overlay {
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
    }
    .shadow(color: .black.opacity(0.18), radius: 5, y: 2)
  }
}
