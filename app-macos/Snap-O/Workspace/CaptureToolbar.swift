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

  @Bindable var controller: CapturePaneSession
  @Bindable var workspace: WorkspaceLayoutController
  let presentation: WorkspacePanePresentation
  let toolModel: ToolHostModel?
  let titlebarHeight: CGFloat

  @Environment(\.openWindow)
  private var openWindow
  @State private var isToolSearchPresented = false

  var body: some View {
    ZStack {
      Color.clear
        .contentShape(Rectangle())

      if presentation.layout.showsCapture {
        captureToolbarPane
          .frame(width: presentation.captureWidth, height: toolbarHeight)
          .frame(width: presentation.captureVisibleWidth, height: toolbarHeight, alignment: .leading)
          .clipped()
          .frame(maxWidth: .infinity, alignment: .leading)
          .zIndex(presentation.zIndex(for: .capture))
      }

      if presentation.layout.showsTool {
        toolToolbarPane
          .frame(width: presentation.toolWidth, height: toolbarHeight)
          .frame(width: presentation.toolVisibleWidth, height: toolbarHeight, alignment: .trailing)
          .clipped()
          .frame(maxWidth: .infinity, alignment: .trailing)
          .zIndex(presentation.zIndex(for: .tool))
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
    guard presentation.captureWidth > 0 else { return 0 }
    return min(max(presentation.captureVisibleWidth / presentation.captureWidth, 0), 1)
  }

  private var toolVisibility: CGFloat {
    guard presentation.toolWidth > 0 else { return 0 }
    return min(max(presentation.toolVisibleWidth / presentation.toolWidth, 0), 1)
  }

  private func captureToolbarControls(compact: Bool = false) -> some View {
    let buttonSize = SnapOToolbarStyle.singleControlSize
    let spacing: CGFloat = compact ? 3 : 8
    let historySpacing: CGFloat = compact ? 2 : 8
    let utilitySpacing: CGFloat = compact ? 3 : 8
    return CaptureToolbarLayout {
      HStack(spacing: 0) {
        if presentation.layout == .both {
          captureToggle()
            .opacity(toolVisibility)
            .allowsHitTesting(toolVisibility > 0.5)
            .accessibilityHidden(toolVisibility < 0.5)
            .frame(width: buttonSize * toolVisibility, alignment: .leading)
            .padding(.trailing, spacing * toolVisibility)
        }
        Spacer(minLength: 0)
      }

      HStack(spacing: spacing) {
        captureControls()
        if !controller.isRecording, controller.canRecordDeviceAudio {
          RecordingAudioButton()
            .disabled(!controller.canStartRecordingNow)
        }
      }

      HStack(spacing: 0) {
        Spacer(minLength: historySpacing)
        historyButton()
        toolToggle()
          .opacity(1 - toolVisibility)
          .allowsHitTesting(toolVisibility < 0.5)
          .accessibilityHidden(toolVisibility > 0.5)
          .frame(width: buttonSize * (1 - toolVisibility), alignment: .trailing)
          .padding(.leading, utilitySpacing * (1 - toolVisibility))
      }
    }
    .controlSize(.extraLarge)
    .snapOToolbarControlStyle()
  }

  private var captureToolbarPane: some View {
    ZStack {
      CaptureToolbarBackground()

      ViewThatFits(in: .horizontal) {
        captureToolbarControls()
          .padding(.horizontal, 12)
        captureToolbarControls(compact: true)
          .padding(.horizontal, 12)
        captureToolbarControls(compact: true)
          .padding(.horizontal, 2)
      }
      .frame(maxWidth: .infinity)
      .frame(height: Self.height)
      .offset(y: titlebarHeight / 2)
    }
  }

  private var toolToolbarPane: some View {
    ZStack {
      Color(nsColor: .textBackgroundColor)

      HStack(spacing: 0) {
        captureToggleSlot

        if let toolModel {
          HStack(spacing: 8) {
            ToolToolbarControls(
              model: toolModel,
              isSearchPresented: $isToolSearchPresented
            )

            AppToolPicker(model: toolModel)
              .padding(.leading, 4)
            AppToolReconnectButton(model: toolModel)
            AppToolViewPicker(model: toolModel)
          }
        }

        Spacer()

        if let toolModel {
          ToolToolbarControls(
            model: toolModel,
            isSearchPresented: $isToolSearchPresented,
            placement: .end
          )
          .padding(.trailing, 8)
        }

        toolToggleSlot
      }
      .frame(height: Self.height)
      .padding(.horizontal, 12)
      .offset(y: titlebarHeight / 2)
      .animation(.easeOut(duration: 0.16), value: isToolSearchPresented)
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

  private var toolToggleSlot: some View {
    let visibility = min(captureVisibility, toolVisibility)
    let width = (SnapOToolbarStyle.singleControlSize + 8) * captureVisibility

    return toolToggle()
      .opacity(visibility)
      .allowsHitTesting(visibility > 0.5)
      .frame(
        width: SnapOToolbarStyle.singleControlSize,
        height: SnapOToolbarStyle.singleControlSize
      )
      .frame(width: width, alignment: .trailing)
  }

  @ViewBuilder
  private func captureControls() -> some View {
    if controller.isRecording {
      recordingControls()
    } else {
      CaptureActionToolbarControls(
        screenshot: { controller.launch(.screenshot) },
        canCaptureNow: controller.canCaptureNow,
        startRecording: { controller.launch(.startRecording) },
        canStartRecordingNow: controller.canStartRecordingNow
      )
    }
  }

  @ViewBuilder
  private func recordingControls() -> some View {
    if controller.isFinishingRecording {
      HStack(spacing: 6) {
        ProgressView()
          .controlSize(.small)
        Text("Stopping")
          .font(.body.weight(.semibold))
          .foregroundStyle(.secondary)
      }
    } else {
      Button {
        controller.launch(.stopRecording)
      } label: {
        Label("Stop", systemImage: "stop.fill")
          .labelStyle(.titleAndIcon)
          .font(.body.weight(.semibold))
          .foregroundStyle(.white)
      }
      .buttonStyle(.borderedProminent)
      .buttonBorderShape(.capsule)
      .tint(.red)
      .help("Stop Recording (⇧⌘V)")
      .accessibilityLabel("Stop Recording")
      .keyboardShortcut("v", modifiers: [.command, .shift])
    }
  }

  private func historyButton() -> some View {
    Button {
      openWindow(id: "capture-history")
    } label: {
      Label("Capture History", systemImage: "clock.arrow.trianglehead.counterclockwise.rotate.90")
        .labelStyle(.iconOnly)
        .font(SnapOToolbarStyle.iconFont)
        .frame(width: SnapOToolbarStyle.singleControlSize, height: SnapOToolbarStyle.singleControlSize)
    }
    .help("Capture History (⌘Y)")
    .controlSize(.extraLarge)
    .snapOToolbarSingleControlStyle()
  }

  private func captureToggle() -> some View {
    Button {
      CommandDiagnostics.shared.paneAction("toggle-capture", source: "toolbar", workspace: workspace)
      workspace.toggleCapture()
    } label: {
      toggleIcon("iphone")
        .symbolRenderingMode(.monochrome)
        .accessibilityLabel("Capture")
    }
    .help(workspace.showsCapture ? "Hide Capture Pane (⌘⌥C)" : "Show Capture Pane (⌘⌥C)")
    .controlSize(.extraLarge)
    .snapOToolbarSingleControlStyle()
    .disabled(!workspace.canToggleCapture)
  }

  private func toolToggle() -> some View {
    Button {
      CommandDiagnostics.shared.paneAction("toggle-tool", source: "toolbar", workspace: workspace)
      workspace.toggleTool()
    } label: {
      toggleIcon("sidebar.right")
        .accessibilityLabel("Tool pane")
    }
    .help(workspace.showsTool ? "Hide Tool Pane (⌘⌥I)" : "Show Tool Pane (⌘⌥I)")
    .controlSize(.extraLarge)
    .snapOToolbarSingleControlStyle()
    .disabled(!workspace.canToggleTool)
  }

  private func toggleIcon(_ systemName: String) -> some View {
    Image(systemName: systemName)
      .font(SnapOToolbarStyle.iconFont)
      .frame(
        width: SnapOToolbarStyle.singleControlSize,
        height: SnapOToolbarStyle.singleControlSize
      )
  }
}

/// Centers the capture controls while leaving room for both ends of the toolbar.
private struct CaptureToolbarLayout: Layout {
  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
    let minimumWidth = sizes.reduce(CGFloat.zero) { $0 + $1.width }
    return CGSize(width: max(minimumWidth, proposal.width ?? 0), height: sizes.map(\.height).max() ?? 0)
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    let leading = subviews[0]
    let capture = subviews[1]
    let trailing = subviews[2]
    let captureWidth = capture.sizeThatFits(.unspecified).width
    let minimumX = bounds.minX + leading.sizeThatFits(.unspecified).width
    let maximumX = bounds.maxX - trailing.sizeThatFits(.unspecified).width - captureWidth
    let captureX = max(minimumX, min(bounds.midX - captureWidth / 2, maximumX))
    let trailingX = captureX + captureWidth
    leading.place(
      at: CGPoint(x: bounds.minX, y: bounds.midY),
      anchor: .leading,
      proposal: ProposedViewSize(width: captureX - bounds.minX, height: bounds.height)
    )
    capture.place(at: CGPoint(x: captureX, y: bounds.midY), anchor: .leading, proposal: .unspecified)
    trailing.place(
      at: CGPoint(x: trailingX, y: bounds.midY),
      anchor: .leading,
      proposal: ProposedViewSize(width: bounds.maxX - trailingX, height: bounds.height)
    )
  }
}

struct CaptureActionToolbarControls: View {
  let screenshot: @MainActor () -> Void
  let canCaptureNow: Bool
  let startRecording: @MainActor () -> Void
  let canStartRecordingNow: Bool
  var unavailableReason: String?
  @Environment(AppSettings.self)
  private var settings

  var body: some View {
    HStack(spacing: 0) {
      Button {
        screenshot()
      } label: {
        CaptureActionIcon(title: "New Screenshot", symbol: "camera")
      }
      .help(unavailableReason ?? "New Screenshot (⇧⌘S)")
      .disabled(!canCaptureNow)

      Button(action: startRecording) {
        CaptureActionIcon(title: "Record", symbol: settings.recordAsBugReport ? "ant.circle" : "record.circle")
      }
      .help(unavailableReason ?? (settings.recordAsBugReport ? "Start Recording Bug Report (⇧⌘V)" : "Start Recording (⇧⌘V)"))
      .disabled(!canStartRecordingNow)
      .contextMenu {
        if settings.recordAsBugReport {
          Button("Disable Bug Report Mode") { settings.recordAsBugReport = false }
        }
      }
    }
    .labelStyle(.iconOnly)
    .controlSize(.extraLarge)
    .snapOToolbarGroupStyle()
  }
}

private struct RecordingAudioButton: View {
  @Environment(AppSettings.self)
  private var settings
  @State private var showsOptions = false

  var body: some View {
    @Bindable var settings = settings
    let mode = RecordingAudioMode(playback: settings.recordDeviceAudio, microphone: settings.recordMicrophone)
    Button {
      showsOptions.toggle()
    } label: {
      RecordingAudioIcon(mode: mode)
        .frame(width: SnapOToolbarStyle.singleControlSize, height: SnapOToolbarStyle.singleControlSize)
        .contentShape(Circle())
    }
    .controlSize(.extraLarge)
    .snapOToolbarSingleControlStyle()
    .accessibilityLabel("Recording audio options")
    .accessibilityValue(mode.accessibilityValue)
    .help("Recording audio options (\(mode.accessibilityValue))")
    .popover(isPresented: $showsOptions, arrowEdge: .bottom) {
      VStack(alignment: .leading, spacing: 10) {
        Toggle("Record Device Audio", isOn: $settings.recordDeviceAudio)
        Toggle("Record Microphone", isOn: $settings.recordMicrophone)
          .help("Record the microphone Android receives. Your voice may be missing while another app uses the mic.")
      }
      .toggleStyle(.checkbox)
      .buttonStyle(.automatic)
      .controlSize(.regular)
      .padding(14)
    }
  }
}
