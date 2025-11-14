import SwiftUI

struct CaptureSnapshotView<Host: LivePreviewHosting>: View {
  @ObservedObject var controller: CaptureSnapshotController
  let fileStore: FileStore
  let livePreviewHost: Host

  var body: some View {
    ZStack {
      if let capture = controller.currentCapture {
        CaptureMediaView(
          fileStore: fileStore,
          livePreviewHost: livePreviewHost,
          capture: capture
        )
        .id(controller.currentCaptureViewID)
      }
    }
    .overlay(alignment: .top) {
      if controller.mediaList.count > 1, controller.shouldShowPreviewHint {
        let captures = controller.overlayMediaList.isEmpty ? controller.mediaList : controller.overlayMediaList
        CapturePreviewStrip(
          captures: captures,
          selectedID: controller.selectedMediaID,
          onSelect: { controller.selectMedia(id: $0) },
          fileStore: fileStore
        )
        .padding(.top, 12)
        .onHover { controller.setPreviewHintHovering($0) }
        .transition(previewStripTransition)
      }
    }
    .animation(.easeInOut(duration: 0.3), value: controller.shouldShowPreviewHint)
  }

  private var previewStripTransition: AnyTransition {
    .offset(CGSize(width: 0, height: -15)).combined(with: .opacity)
  }
}
