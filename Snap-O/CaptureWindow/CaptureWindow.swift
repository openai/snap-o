import SwiftUI

struct CaptureWindow: View {
  let appCoordinator: AppCoordinator

  @State private var windowCoordinator: CaptureWindowCoordinator

  init(appCoordinator: AppCoordinator) {
    self.appCoordinator = appCoordinator
    _windowCoordinator = State(
      initialValue: CaptureWindowCoordinator(appCoordinator: appCoordinator)
    )
  }

  var body: some View {
    CaptureContentView(coordinator: windowCoordinator, deviceStore: appCoordinator.deviceStore)
      .focusedSceneValue(\.captureWindow, windowCoordinator)
      .toolbar {
        ToolbarItemGroup(placement: .primaryAction) {
          Button {
            Task { await windowCoordinator.refreshPreview() }
          } label: {
            Label("New Screenshot", systemImage: "camera")
              .labelStyle(.iconOnly)
          }
          .help("New Screenshot (⌘R)")
          .disabled(windowCoordinator.canCapture != true)
          .keyboardShortcut("r", modifiers: [.command])

          if windowCoordinator.captureVM.isRecording {
            Button {
              Task { await windowCoordinator.stopRecording() }
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
              Task { await windowCoordinator.startRecording() }
            } label: {
              Label("Record", systemImage: "record.circle")
            }
            .help("Start Recording (⌘⇧R)")
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(windowCoordinator.canStartRecordingNow != true)
          }

          ToolbarDivider()

          if windowCoordinator.captureVM.isLivePreviewing {
            Button {
              windowCoordinator.stopLivePreview(refreshPreview: true)
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
              Task { await windowCoordinator.startLivePreview() }
            } label: {
              Label("Live", systemImage: "play.circle")
            }
            .help("Live Preview (⌘⇧L)")
            .keyboardShortcut("l", modifiers: [.command, .shift])
            .disabled(windowCoordinator.canStartLivePreviewNow != true)
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
