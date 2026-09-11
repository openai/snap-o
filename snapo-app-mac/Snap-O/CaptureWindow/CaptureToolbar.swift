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
  let inspectorModel: InspectorHostModel?
  let capturePaneWidth: CGFloat
  let inspectorPaneWidth: CGFloat
  let capturePaneVisibleWidth: CGFloat
  let inspectorPaneVisibleWidth: CGFloat
  let transitioningPane: WorkspaceLayoutTransition.Pane?
  let titlebarHeight: CGFloat

  @Environment(AppSettings.self)
  private var settings
  @State private var isInspectorSearchPresented = false

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

      if presentedLayout.showsInspector {
        inspectorToolbarPane
          .frame(width: inspectorPaneWidth, height: toolbarHeight)
          .frame(width: inspectorPaneVisibleWidth, height: toolbarHeight, alignment: .trailing)
          .clipped()
          .frame(maxWidth: .infinity, alignment: .trailing)
          .zIndex(paneZIndex(.inspector))
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

  private var inspectorVisibility: CGFloat {
    guard inspectorPaneWidth > 0 else { return 0 }
    return min(max(inspectorPaneVisibleWidth / inspectorPaneWidth, 0), 1)
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
            .opacity(inspectorVisibility)
            .allowsHitTesting(inspectorVisibility > 0.5)
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
          inspectorToggle()
            .opacity(1 - inspectorVisibility)
            .allowsHitTesting(inspectorVisibility < 0.5)
        }
        .frame(height: Self.height)
        .padding(.trailing, 12)
        .offset(y: titlebarHeight / 2)
      }
    }
  }

  private var inspectorToolbarPane: some View {
    ZStack {
      Color(nsColor: .textBackgroundColor)

      HStack(spacing: 0) {
        captureToggleSlot

        if let inspectorModel {
          HStack(spacing: 8) {
            InspectorToolbarControls(
              model: inspectorModel,
              isSearchPresented: $isInspectorSearchPresented
            )

            AppInspectorPicker(model: inspectorModel)
              .padding(.leading, 4)
            AppInspectorReconnectButton(model: inspectorModel)
            AppInspectorViewPicker(model: inspectorModel)
          }
        }

        Spacer()

        if let inspectorModel {
          InspectorToolbarControls(
            model: inspectorModel,
            isSearchPresented: $isInspectorSearchPresented,
            placement: .end
          )
          .padding(.trailing, 8)
        }

        inspectorToggleSlot
      }
      .frame(height: Self.height)
      .padding(.horizontal, 12)
      .offset(y: titlebarHeight / 2)
      .animation(.easeOut(duration: 0.16), value: isInspectorSearchPresented)
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

  private var inspectorToggleSlot: some View {
    let visibility = min(captureVisibility, inspectorVisibility)
    let width = (SnapOToolbarStyle.singleControlSize + 8) * captureVisibility

    return inspectorToggle()
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
    } else {
      CaptureActionToolbarControls(
        screenshot: { Task { await controller.captureScreenshots() } },
        canCaptureNow: controller.canCaptureNow,
        isShowingScreenshot: !controller.isLivePreviewActive && controller.currentCapture?.media.isImage == true,
        startRecording: { Task { await controller.startRecording() } },
        canStartRecordingNow: controller.canStartRecordingNow,
        isShowingRecording: !controller.isLivePreviewActive && controller.currentCapture?.media.isVideo == true,
        startLivePreview: { Task { await controller.startLivePreview() } },
        canSelectLivePreview: controller.canSelectLivePreview,
        isLivePreviewActive: controller.isLivePreviewActive
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
      .help("Stopping Recording")
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

  private func inspectorToggle() -> some View {
    Button {
      workspace.toggleInspector()
    } label: {
      toggleIcon("sidebar.right")
        .accessibilityLabel("App Inspector")
    }
    .help(workspace.showsInspector ? "Hide App Inspector (⌘⌥I)" : "Show App Inspector (⌘⌥I)")
    .controlSize(.extraLarge)
    .snapOToolbarSingleControlStyle()
    .disabled(!workspace.canToggleInspector)
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
    let canBrowseCaptures = !isCaptureInFlight && controller.hasAlternativeMedia()

    return CaptureSelectionPill(position: progress)
      .opacity(isCaptureInFlight ? 0.45 : 1)
      .allowsHitTesting(!isCaptureInFlight)
      .onHover { hovering in
        guard canBrowseCaptures else {
          if !hovering { controller.setProgressHovering(false) }
          return
        }
        controller.setProgressHovering(hovering)
      }
      .onChange(of: canBrowseCaptures) {
        guard !canBrowseCaptures else { return }
        controller.setProgressHovering(false)
      }
  }
}

struct CaptureActionToolbarControls: View {
  let screenshot: @MainActor () -> Void
  let canCaptureNow: Bool
  let isShowingScreenshot: Bool
  let startRecording: @MainActor () -> Void
  let canStartRecordingNow: Bool
  let isShowingRecording: Bool
  let startLivePreview: @MainActor () -> Void
  let canSelectLivePreview: Bool
  let isLivePreviewActive: Bool
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
          .modifier(CaptureSelectionHighlight(isSelected: isShowingScreenshot))
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
            .modifier(CaptureSelectionHighlight(isSelected: isShowingRecording))
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
            .modifier(CaptureSelectionHighlight(isSelected: isShowingRecording))
        }
        .help("Start Recording (⌘⇧R)")
        .disabled(!canStartRecordingNow)
      }

      Button {
        startLivePreview()
      } label: {
        Label("Live Preview", systemImage: "play.circle")
          .font(SnapOToolbarStyle.iconFont)
          .frame(width: 34, height: 32)
          .modifier(CaptureSelectionHighlight(isSelected: isLivePreviewActive))
      }
      .help("Live Preview (⌘⇧L). Option-drag the preview to capture a frame.")
      .disabled(!canSelectLivePreview)
    }
    .labelStyle(.iconOnly)
    .controlSize(.extraLarge)
    .snapOToolbarGroupStyle()
  }
}

private struct CaptureSelectionHighlight: ViewModifier {
  let isSelected: Bool

  func body(content: Content) -> some View {
    if isSelected {
      content.foregroundStyle(.blue)
    } else {
      content
    }
  }
}
