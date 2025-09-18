import AppKit
import AVFoundation
import SwiftUI

struct CaptureWindow: View {
  @StateObject private var controller = CaptureWindowController()

  var body: some View {
    ZStack {
      Color.black.ignoresSafeArea()

      let transition = transition(for: controller.transitionDirection)

      if let capture = controller.currentCapture {
        CaptureMediaView(
          controller: controller,
          capture: capture
        )
        .id(controller.currentCaptureViewID)
        .zIndex(1)
        .transition(transition)
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
      CaptureToolbar(controller: controller)

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
    .overlay(alignment: .top) {
      if controller.mediaList.count > 1 {
        let captures = controller.overlayMediaList.isEmpty ? controller.mediaList : controller.overlayMediaList
        CapturePreviewStrip(
          captures: captures,
          selectedID: controller.selectedMediaID
        ) { controller.selectMedia(id: $0) }
          .opacity(controller.shouldShowPreviewHint ? 1 : 0)
          .offset(y: controller.shouldShowPreviewHint ? 0 : -20)
          .padding(.top, 12)
          .allowsHitTesting(controller.shouldShowPreviewHint)
          .onHover { controller.setPreviewHintHovering($0) }
          .animation(.easeInOut(duration: 0.35), value: controller.shouldShowPreviewHint)
      }
    }
    .animation(.snappy(duration: 0.25), value: controller.currentCaptureViewID)
  }
}

extension CaptureWindow {
  private func transition(for direction: DeviceTransitionDirection) -> AnyTransition {
    switch direction {
    case .previous: xTransition(insertion: .leading, removal: .trailing)
    case .next: xTransition(insertion: .trailing, removal: .leading)
    case .neutral: .opacity
    }
  }

  private func xTransition(insertion: Edge, removal: Edge) -> AnyTransition {
    .asymmetric(
      insertion: .move(edge: insertion).combined(with: .opacity),
      removal: .move(edge: removal).combined(with: .opacity)
    )
  }
}
