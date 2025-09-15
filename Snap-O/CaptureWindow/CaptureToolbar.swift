import SwiftUI

struct CaptureToolbar: ToolbarContent {
  @ObservedObject var controller: CaptureWindowController

  var body: some ToolbarContent {
    ToolbarItemGroup(placement: .primaryAction) {
      if controller.isRecording {
        recordingControls()
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
  private func idleControls() -> some View {
    Button {
      Task { await controller.captureScreenshots() }
    } label: {
      Label("New Screenshot", systemImage: "camera")
        .labelStyle(.iconOnly)
    }
    .help("New Screenshot (⌘R)")
    .disabled(!controller.hasDevices || controller.isProcessing)

    Button {
      Task { await controller.startRecording() }
    } label: {
      Label("Record", systemImage: "record.circle")
    }
    .help("Start Recording (⌘⇧R)")
    .disabled(!controller.hasDevices || controller.isProcessing)
  }
}
