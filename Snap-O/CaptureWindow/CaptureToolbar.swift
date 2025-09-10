import SwiftUI

struct CaptureToolbar: ToolbarContent {
  @ObservedObject var controller: CaptureController

  var body: some ToolbarContent {
    ToolbarItemGroup(placement: .primaryAction) {
      if controller.isRecording {
        recordingControls()
      } else if controller.isLivePreviewActive || controller.isStoppingLivePreview {
        livePreviewControls(isStopping: controller.isStoppingLivePreview)
      } else {
        idleControls()
      }
    }
  }

  @ViewBuilder
  private func recordingControls() -> some View {
    Button {
      Task { await controller.stopRecording() }
    } label: {
      Label("Stop", systemImage: "stop.fill")
        .fontWeight(.semibold)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.red))
        .foregroundStyle(Color.white)
    }
    .buttonStyle(.plain)
    .help("Stop Recording (⎋)")
    .keyboardShortcut(.escape, modifiers: [])
  }

  @ViewBuilder
  private func livePreviewControls(isStopping: Bool) -> some View {
    Button {
      Task { await controller.stopLivePreview(withRefresh: true) }
    } label: {
      Label("Live", systemImage: "pause.fill")
        .fontWeight(.semibold)
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(.blue))
        .foregroundStyle(Color.white)
    }
    .buttonStyle(.plain)
    .help("Stop Preview (⎋)")
    .keyboardShortcut(.escape, modifiers: [])
    .disabled(isStopping)
  }

  @ViewBuilder
  private func idleControls() -> some View {
    Button {
      Task { await controller.refreshPreview() }
    } label: {
      Label("New Screenshot", systemImage: "camera")
        .labelStyle(.iconOnly)
    }
    .help("New Screenshot (⌘R)")
    .disabled(controller.canCapture != true)

    Button {
      Task { await controller.startRecording() }
    } label: {
      Label("Record", systemImage: "record.circle")
    }
    .help("Start Recording (⌘⇧R)")
    .disabled(controller.canStartRecordingNow != true)

    ToolbarDivider()

    Button {
      Task { await controller.startLivePreview() }
    } label: {
      Label("Live", systemImage: "play.circle")
    }
    .help("Live Preview (⌘⇧L)")
    .disabled(controller.canStartLivePreviewNow != true)
  }
}

private struct ToolbarDivider: View {
  var body: some View {
    Rectangle()
      .frame(width: 1, height: 22)
      .opacity(0.2) // adapts in dark/light
      .accessibilityHidden(true)
  }
}
