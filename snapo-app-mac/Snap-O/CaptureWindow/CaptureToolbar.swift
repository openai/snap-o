import Observation
import SwiftUI

struct CaptureToolbar: ToolbarContent {
  @Bindable var controller: CaptureWindowController
  @Environment(AppSettings.self)
  private var settings
  @Environment(\.openWindow)
  private var openWindow

  var body: some ToolbarContent {
    if controller.isRecording {
      ToolbarItemGroup(placement: .principal) {
        recordingControls()
      }
    } else if controller.isLivePreviewActive || controller.isStoppingLivePreview {
      ToolbarItemGroup(placement: .principal) {
        livePreviewControls()
      }
    } else {
      IdleToolbarControls(
        screenshot: { Task { await controller.captureScreenshots() } },
        canCaptureNow: controller.canCaptureNow,
        startRecording: { Task { await controller.startRecording() } },
        canStartRecordingNow: controller.canStartRecordingNow,
        startLivePreview: { Task { await controller.startLivePreview() } },
        canStartLivePreviewNow: controller.canStartLivePreviewNow
      )
    }
    ToolbarItemGroup(placement: .primaryAction) {
      toolControls()
    }
  }

  @ViewBuilder
  private func recordingControls() -> some View {
    let bugReportEnabled = settings.recordAsBugReport

    if controller.isProcessing {
      Button {} label: {
        ProgressView()
          .progressViewStyle(.circular)
          .controlSize(.small)
          .help("Stopping Recording…")
          .disabled(true)
      }
    } else {
      Button {
        Task { await controller.stopRecording() }
      } label: {
        Label("Stop Recording", systemImage: bugReportEnabled ? "ant.circle" : "record.circle")
          .symbolEffect(.pulse)
          .foregroundStyle(.red)
      }
      .help("Stop Recording (⎋)")
      .keyboardShortcut(.escape, modifiers: [])
    }
  }

  private func livePreviewControls() -> some View {
    Button {
      Task { await controller.stopLivePreview() }
    } label: {
      Label("Live", systemImage: "play.circle")
        .symbolEffect(.pulse)
        .foregroundStyle(.blue)
    }
    .help("Stop Live Preview (⎋)")
    .keyboardShortcut(.escape, modifiers: [])
    .disabled(controller.isStoppingLivePreview)
  }

  @ViewBuilder
  private func toolControls() -> some View {
    Button {
      NetworkInspectorHelperLauncher.open()
    } label: {
      Label("Network Inspector", systemImage: "network")
        .labelStyle(.iconOnly)
    }
    .controlSize(.large)
    .help("Network Inspector (⌘⌥I)")
    Button {
      openWindow(id: LogcatWindowID.main)
    } label: {
      Label("Logcat Viewer", systemImage: "list.bullet.rectangle")
        .labelStyle(.iconOnly)
    }
    .controlSize(.large)
    .help("Logcat Viewer (⌘⌥L)")
  }
}

struct IdleToolbarControls: ToolbarContent {
  let screenshot: @MainActor () -> Void
  let canCaptureNow: Bool
  let startRecording: @MainActor () -> Void
  let canStartRecordingNow: Bool
  let startLivePreview: @MainActor () -> Void
  let canStartLivePreviewNow: Bool
  @Environment(AppSettings.self)
  private var settings

  var body: some ToolbarContent {
    ToolbarItemGroup(placement: .principal) {
      Button {
        screenshot()
      } label: {
        Label("New Screenshot", systemImage: "camera")
          .labelStyle(.iconOnly)
      }
      .help("New Screenshot (⌘R)")
      .disabled(!canCaptureNow)
      .controlSize(.large)

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
        .menuIndicator(.hidden)
        .menuStyle(.button)
        .help("Start Recording Bug Report (⌘⇧R)")
        .disabled(!canStartRecordingNow)
        .controlSize(.large)
      } else {
        Button {
          startRecording()
        } label: {
          Label("Record", systemImage: "record.circle")
        }
        .help("Start Recording (⌘⇧R)")
        .disabled(!canStartRecordingNow)
        .controlSize(.large)
      }

      Button {
        startLivePreview()
      } label: {
        Label("Live", systemImage: "play.circle")
      }
      .help("Live Preview (⌘⇧L)")
      .disabled(!canStartLivePreviewNow)
      .controlSize(.large)
    }
  }
}
