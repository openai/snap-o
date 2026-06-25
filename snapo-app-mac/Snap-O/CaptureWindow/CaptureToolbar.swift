import AppKit
import Observation
import SwiftUI

private final class CaptureToolbarBackgroundView: NSVisualEffectView {
  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    material = .headerView
    blendingMode = .behindWindow
    state = .followsWindowActiveState
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    nil
  }
}

private struct CaptureToolbarBackground: NSViewRepresentable {
  func makeNSView(context: Context) -> CaptureToolbarBackgroundView {
    CaptureToolbarBackgroundView(frame: .zero)
  }

  func updateNSView(_ nsView: CaptureToolbarBackgroundView, context: Context) {}
}

struct CaptureToolbar: View {
  static let height: CGFloat = 52

  @Bindable var controller: CaptureWindowController
  @Bindable var workspace: WorkspaceLayoutController
  let presentedLayout: WorkspaceLayout
  let networkModel: NetworkInspectorHostModel?
  let capturePaneWidth: CGFloat
  let networkPaneWidth: CGFloat
  let capturePaneVisibleWidth: CGFloat
  let networkPaneVisibleWidth: CGFloat
  let transitioningPane: WorkspaceLayoutTransition.Pane?
  let titlebarHeight: CGFloat

  @Environment(AppSettings.self)
  private var settings
  @State private var isNetworkSearchPresented = false

  var body: some View {
    ZStack {
      Color.clear
        .contentShape(Rectangle())

      if presentedLayout.showsCapture {
        captureToolbarPane
          .frame(width: capturePaneWidth, height: toolbarHeight)
          .frame(width: capturePaneVisibleWidth, height: toolbarHeight, alignment: .leading)
          .clipped()
          .frame(maxWidth: .infinity, alignment: .leading)
          .zIndex(paneZIndex(.capture))
      }

      if presentedLayout.showsNetwork {
        networkToolbarPane
          .frame(width: networkPaneWidth, height: toolbarHeight)
          .frame(width: networkPaneVisibleWidth, height: toolbarHeight, alignment: .trailing)
          .clipped()
          .frame(maxWidth: .infinity, alignment: .trailing)
          .zIndex(paneZIndex(.network))
      }
    }
    .simultaneousGesture(WindowDragGesture())
    .frame(height: toolbarHeight)
    .overlay(alignment: .bottom) {
      Divider()
    }
  }

  private var toolbarHeight: CGFloat {
    titlebarHeight + Self.height
  }

  private var captureVisibility: CGFloat {
    guard capturePaneWidth > 0 else { return 0 }
    return min(max(capturePaneVisibleWidth / capturePaneWidth, 0), 1)
  }

  private var networkVisibility: CGFloat {
    guard networkPaneWidth > 0 else { return 0 }
    return min(max(networkPaneVisibleWidth / networkPaneWidth, 0), 1)
  }

  private var captureToolbarPane: some View {
    ZStack {
      CaptureToolbarBackground()

      HStack(spacing: 15) {
        captureControls()

        if !controller.isRecording, let progress = controller.captureProgressText {
          captureProgress(progress)
        }
      }
      .controlSize(.extraLarge)
      .snapOToolbarControlStyle()
      .frame(height: Self.height)
      .offset(y: titlebarHeight / 2)

      if presentedLayout == .both {
        HStack {
          captureToggle()
            .opacity(networkVisibility)
            .allowsHitTesting(networkVisibility > 0.5)
          Spacer()
        }
        .frame(height: Self.height)
        .padding(.leading, 12)
        .frame(maxWidth: .infinity)
        .offset(y: titlebarHeight / 2)
      }

      if presentedLayout.showsCapture {
        HStack {
          Spacer()
          networkToggle()
            .opacity(1 - networkVisibility)
            .allowsHitTesting(networkVisibility < 0.5)
        }
        .frame(height: Self.height)
        .padding(.trailing, 12)
        .offset(y: titlebarHeight / 2)
      }
    }
  }

  private var networkToolbarPane: some View {
    ZStack {
      Color(nsColor: .textBackgroundColor)

      HStack(spacing: 0) {
        captureToggleSlot

        if let networkModel {
          HStack(spacing: 8) {
            NetworkInspectorToolbarControls(
              model: networkModel,
              isSearchPresented: $isNetworkSearchPresented
            )
            NetworkInspectorServerPicker(model: networkModel)
              .padding(.leading, 4)
          }
        }

        Spacer()

        if let networkModel {
          NetworkInspectorExportMenu(model: networkModel)
        }

        networkToggleSlot
      }
      .frame(height: Self.height)
      .padding(.horizontal, 12)
      .offset(y: titlebarHeight / 2)
      .animation(.easeOut(duration: 0.16), value: isNetworkSearchPresented)
    }
  }

  private var captureToggleSlot: some View {
    let visibility = 1 - captureVisibility
    let width = (SnapOToolbarStyle.singleControlSize + 8) * visibility

    return captureToggle()
      .opacity(visibility)
      .allowsHitTesting(visibility > 0.5)
      .frame(
        width: SnapOToolbarStyle.singleControlSize,
        height: SnapOToolbarStyle.singleControlSize
      )
      .frame(width: width, alignment: .leading)
  }

  private var networkToggleSlot: some View {
    let visibility = min(captureVisibility, networkVisibility)
    let width = (SnapOToolbarStyle.singleControlSize + 8) * captureVisibility

    return networkToggle()
      .opacity(visibility)
      .allowsHitTesting(visibility > 0.5)
      .frame(
        width: SnapOToolbarStyle.singleControlSize,
        height: SnapOToolbarStyle.singleControlSize
      )
      .frame(width: width, alignment: .trailing)
  }

  private func paneZIndex(_ pane: WorkspaceLayoutTransition.Pane) -> Double {
    guard let transitioningPane else { return 0 }
    return transitioningPane == pane ? 0 : 1
  }

  @ViewBuilder
  private func captureControls() -> some View {
    if controller.isRecording {
      recordingControls()
    } else if controller.isLivePreviewActive || controller.isStoppingLivePreview {
      livePreviewControls()
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
  }

  @ViewBuilder
  private func recordingControls() -> some View {
    let bugReportEnabled = settings.recordAsBugReport

    if controller.isProcessing {
      Button {} label: {
        ProgressView()
          .progressViewStyle(.circular)
          .controlSize(.small)
      }
      .help("Stopping Recording…")
      .disabled(true)
    } else {
      Button {
        Task { await controller.stopRecording() }
      } label: {
        Label("Stop Recording", systemImage: bugReportEnabled ? "ant.circle" : "record.circle")
          .labelStyle(.iconOnly)
          .font(SnapOToolbarStyle.iconFont)
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
        .labelStyle(.iconOnly)
        .font(SnapOToolbarStyle.iconFont)
        .symbolEffect(.pulse)
        .foregroundStyle(.blue)
    }
    .help("Stop Live Preview (⎋)")
    .keyboardShortcut(.escape, modifiers: [])
    .disabled(controller.isStoppingLivePreview)
  }

  private func captureToggle() -> some View {
    Button {
      workspace.toggleCapture()
    } label: {
      toggleIcon("iphone")
        .symbolRenderingMode(.monochrome)
        .accessibilityLabel("Capture")
    }
    .help(workspace.showsCapture ? "Hide Capture" : "Show Capture")
    .controlSize(.extraLarge)
    .snapOToolbarSingleControlStyle()
    .disabled(!workspace.canToggleCapture)
  }

  private func networkToggle() -> some View {
    Button {
      workspace.toggleNetwork()
    } label: {
      toggleIcon("network")
        .accessibilityLabel("Network Inspector")
    }
    .help(workspace.showsNetwork ? "Hide Network Inspector (⌘⌥I)" : "Show Network Inspector (⌘⌥I)")
    .controlSize(.extraLarge)
    .snapOToolbarSingleControlStyle()
    .disabled(!workspace.canToggleNetwork)
  }

  private func toggleIcon(_ systemName: String) -> some View {
    Image(systemName: systemName)
      .font(SnapOToolbarStyle.iconFont)
      .frame(
        width: SnapOToolbarStyle.singleControlSize,
        height: SnapOToolbarStyle.singleControlSize
      )
  }

  private func captureProgress(_ progress: String) -> some View {
    let isCaptureInFlight = controller.isProcessing || controller.isRecording

    return Text(progress)
      .font(.system(size: 12, weight: .semibold, design: .rounded))
      .padding(.horizontal, 10)
      .padding(.vertical, 5)
      .fixedSize()
      .background(.regularMaterial, in: Capsule())
      .opacity(isCaptureInFlight ? 0.45 : 1)
      .allowsHitTesting(!isCaptureInFlight)
      .onHover { hovering in
        guard !isCaptureInFlight else {
          if !hovering { controller.setProgressHovering(false) }
          return
        }
        controller.setProgressHovering(hovering)
      }
      .onChange(of: isCaptureInFlight) {
        guard isCaptureInFlight else { return }
        controller.setProgressHovering(false)
      }
  }
}

struct IdleToolbarControls: View {
  let screenshot: @MainActor () -> Void
  let canCaptureNow: Bool
  let startRecording: @MainActor () -> Void
  let canStartRecordingNow: Bool
  let startLivePreview: @MainActor () -> Void
  let canStartLivePreviewNow: Bool
  @Environment(AppSettings.self)
  private var settings

  var body: some View {
    HStack(spacing: 0) {
      Button {
        screenshot()
      } label: {
        Label("New Screenshot", systemImage: "camera")
          .labelStyle(.iconOnly)
          .font(SnapOToolbarStyle.iconFont)
          .frame(width: 34, height: 32)
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
            .font(SnapOToolbarStyle.iconFont)
            .frame(width: 34, height: 32)
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
      } else {
        Button {
          startRecording()
        } label: {
          Label("Record", systemImage: "record.circle")
            .font(SnapOToolbarStyle.iconFont)
            .frame(width: 34, height: 32)
        }
        .help("Start Recording (⌘⇧R)")
        .disabled(!canStartRecordingNow)
      }

      Button {
        startLivePreview()
      } label: {
        Label("Live", systemImage: "play.circle")
          .font(SnapOToolbarStyle.iconFont)
          .frame(width: 34, height: 32)
      }
      .help("Live Preview (⌘⇧L)")
      .disabled(!canStartLivePreviewNow)
    }
    .labelStyle(.iconOnly)
    .controlSize(.extraLarge)
    .snapOToolbarGroupStyle()
  }
}
