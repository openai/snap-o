import SwiftUI

struct CaptureSnapshotView<Host: LivePreviewHosting>: View {
  @ObservedObject var controller: CaptureSnapshotController
  let livePreviewHost: Host

  var body: some View {
    ZStack {
      if let capture = controller.currentCapture {
        CaptureMediaView(
          livePreviewHost: livePreviewHost,
          capture: capture
        )
        .id(controller.currentCaptureViewID)
        .zIndex(1)
        .transition(transition(for: controller.transitionDirection))
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
