import SwiftUI

struct CaptureToolbar: ToolbarContent {
  @ObservedObject var controller: CaptureWindowController
  @ObservedObject var settings: AppSettings

  var body: some ToolbarContent {
    if controller.isRecording {
      ToolbarItemGroup(placement: .primaryAction) {
        recordingControls()
      }
    } else if controller.isLivePreviewActive || controller.isStoppingLivePreview {
      ToolbarItemGroup(placement: .primaryAction) {
        livePreviewControls()
      }
    } else {
      IdleToolbarControls(
        settings: settings,
        screenshot: { Task { await controller.captureScreenshots() } },
        canCaptureNow: controller.canCaptureNow,
        startRecording: { Task { await controller.startRecording() } },
        canStartRecordingNow: controller.canStartRecordingNow,
        startLivePreview: { Task { await controller.startLivePreview() } },
        canStartLivePreviewNow: controller.canStartLivePreviewNow
      )
    }
  }

  @ViewBuilder
  private func recordingControls() -> some View {
    let bugReportEnabled = settings.recordAsBugReport

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
        Label("Stop Recording", systemImage: bugReportEnabled ? "ant.fill" : "stop.fill")
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
}

struct IdleToolbarControls: ToolbarContent {
  @ObservedObject var settings: AppSettings
  let screenshot: @MainActor () -> Void
  let canCaptureNow: Bool
  let startRecording: @MainActor () -> Void
  let canStartRecordingNow: Bool
  let startLivePreview: @MainActor () -> Void
  let canStartLivePreviewNow: Bool

  var body: some ToolbarContent {
    ToolbarItemGroup(placement: .primaryAction) {
      Button {
        screenshot()
      } label: {
        Label("New Screenshot", systemImage: "camera")
          .labelStyle(.iconOnly)
      }
      .help("New Screenshot (⌘R)")
      .disabled(!canCaptureNow)

      if settings.recordAsBugReport {
        Menu {
          Button("Disable Bug Report Mode") {
            settings.recordAsBugReport = false
          }
        } label: {
          Label("Record", systemImage: "ant.circle")
        } primaryAction: {
          startRecording()
        }
        .overlay(alignment: .bottomTrailing) {
          Image(systemName: "chevron.down")
            .font(.system(size: 5, weight: .bold))
            .offset(x: -6, y: -2)
        }
        .padding(.horizontal, -3)
        .menuIndicator(.hidden)
        .menuStyle(.button)
        .help("Start Recording Bug Report (⌘⇧R)")
        .disabled(!canStartRecordingNow)
      } else {
        Button {
          startRecording()
        } label: {
          Label("Record", systemImage: "record.circle")
        }
        .help("Start Recording (⌘⇧R)")
        .disabled(!canStartRecordingNow)
      }

      Button {
        startLivePreview()
      } label: {
        Label("Live", systemImage: "play.circle")
      }
      .help("Live Preview (⌘⇧L)")
      .disabled(!canStartLivePreviewNow)
    }
  }
}
