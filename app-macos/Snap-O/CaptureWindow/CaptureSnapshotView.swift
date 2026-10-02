import Observation
import SwiftUI

struct CaptureSnapshotView<Host: LivePreviewHosting>: View {
  @Bindable var controller: CaptureSnapshotController
  let fileStore: FileStore
  let livePreviewHost: Host
  let previewCaptures: [CaptureMedia]
  let selectMedia: (CaptureMedia.ID) -> Void

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
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .overlay(alignment: .top) {
      if controller.shouldShowPreviewHint, previewCaptures.count > 1 {
        CapturePreviewStrip(
          captures: previewCaptures,
          selectedID: controller.selectedMediaID,
          onSelect: selectMedia,
          fileStore: fileStore,
          livePreviewHost: livePreviewHost
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
