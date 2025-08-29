import SwiftUI

struct CaptureWindow: View {
  let services: AppServices

  @State private var coordinator: CaptureWindowCoordinator

  init(services: AppServices) {
    self.services = services
    _coordinator = State(initialValue: CaptureWindowCoordinator(services: services))
  }

  var body: some View {
    CaptureContentView(coordinator: coordinator, deviceStore: services.deviceService.store)
      .focusedSceneValue(\.captureWindow, coordinator)
      .toolbar {
        ToolbarItemGroup(placement: .primaryAction) {
          Button {
            Task { await coordinator.refreshPreview() }
          } label: {
            Label("New Screenshot", systemImage: "camera")
              .labelStyle(.iconOnly)
          }
          .help("New Screenshot (⌘R)")
          .disabled(coordinator.canCapture != true)
          .keyboardShortcut("r", modifiers: [.command])

          if coordinator.captureVM.isRecording {
            Button {
              Task { await coordinator.stopRecording() }
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
          } else {
            Button {
              Task { await coordinator.startRecording() }
            } label: {
              Label("Record", systemImage: "record.circle")
            }
            .help("Start Recording (⌘⇧R)")
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(coordinator.canStartRecordingNow != true)
          }

          ToolbarDivider()

          if coordinator.captureVM.currentMedia?.isLivePreview == true {
            Button {
              Task { await coordinator.stopLivePreview(refreshPreview: true) }
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
              Task { await coordinator.startLivePreview() }
            } label: {
              Label("Live", systemImage: "play.circle")
            }
            .help("Live Preview (⌘⇧L)")
            .keyboardShortcut("l", modifiers: [.command, .shift])
            .disabled(coordinator.canStartLivePreviewNow != true)
          }
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
