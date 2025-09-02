import SwiftUI

struct CaptureToolbar: ToolbarContent {
  let controller: CaptureController

  var body: some ToolbarContent {
    ToolbarItemGroup(placement: .primaryAction) {
      let isRecording = controller.isRecording
      let isLivePreview = (controller.currentMedia?.isLivePreview == true)

      // Show only the active-stop action when engaged; otherwise show all controls
      if isRecording {
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
      } else if isLivePreview {
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
      } else {
        Button {
          Task { await controller.refreshPreview() }
        } label: {
          Label("New Screenshot", systemImage: "camera")
            .labelStyle(.iconOnly)
        }
        .help("New Screenshot (⌘R)")
        .disabled(controller.canCapture != true)
        .keyboardShortcut("r", modifiers: [.command])

        Button {
          Task { await controller.startRecording() }
        } label: {
          Label("Record", systemImage: "record.circle")
        }
        .help("Start Recording (⌘⇧R)")
        .keyboardShortcut("r", modifiers: [.command, .shift])
        .disabled(controller.canStartRecordingNow != true)

        ToolbarDivider()

        Button {
          Task { await controller.startLivePreview() }
        } label: {
          Label("Live", systemImage: "play.circle")
        }
        .help("Live Preview (⌘⇧L)")
        .keyboardShortcut("l", modifiers: [.command, .shift])
        .disabled(controller.canStartLivePreviewNow != true)
      }
    }
  }
}

struct ToolbarDivider: View {
  var body: some View {
    Rectangle()
      .frame(width: 1, height: 22)
      .opacity(0.2) // adapts in dark/light
      .accessibilityHidden(true)
  }
}
