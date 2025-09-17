import SwiftUI

struct CaptureToolbar: ToolbarContent {
  @ObservedObject var controller: CaptureWindowController

  var body: some ToolbarContent {
    ToolbarItemGroup(placement: .primaryAction) {
      if controller.isRecording {
        recordingControls()
      } else if controller.isLivePreviewActive || controller.isStoppingLivePreview {
        livePreviewControls()
      } else {
        idleControls()
      }
    }
  }

  @ViewBuilder
  private func recordingControls() -> some View {
    if controller.isProcessing {
      ProgressView()
        .progressViewStyle(.circular)
        .tint(.red)
        .controlSize(.small)
        .frame(width: 24, height: 24)
        .help("Stopping Recording…")
    } else {
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
  }

  @ViewBuilder
  private func livePreviewControls() -> some View {
    Button {
      Task { await controller.stopLivePreview() }
    } label: {
      Label("Live", systemImage: "pause.fill")
        .fontWeight(.semibold)
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(.blue))
        .foregroundStyle(Color.white)
    }
    .buttonStyle(.plain)
    .help("Stop Live Preview (⎋)")
    .keyboardShortcut(.escape, modifiers: [])
    .disabled(controller.isStoppingLivePreview)
  }

  @ViewBuilder
  private func idleControls() -> some View {
    Rectangle()
      .frame(width: 1, height: 24)
      .foregroundStyle(.separator)

    Button {
      Task { await controller.captureScreenshots() }
    } label: {
      Label("New Screenshot", systemImage: "camera")
        .labelStyle(.iconOnly)
    }
    .help("New Screenshot (⌘R)")
    .disabled(!controller.canCaptureNow)

    Button {
      Task { await controller.startRecording() }
    } label: {
      Label("Record", systemImage: "record.circle")
    }
    .help("Start Recording (⌘⇧R)")
    .disabled(!controller.canStartRecordingNow)

    Button {
      Task { await controller.startLivePreview() }
    } label: {
      Label("Live", systemImage: "play.circle")
    }
    .help("Live Preview (⌘⇧L)")
    .disabled(!controller.canStartLivePreviewNow)
  }
}
