import AppKit
import Observation
import SwiftUI

private enum CaptureToolbarStyle {
  static let iconFont = Font.system(size: 17, weight: .medium)
}

struct CaptureToolbar: View {
  static let height: CGFloat = 52

  @Bindable var controller: CaptureWindowController
  @Bindable var workspace: WorkspaceLayoutController
  let presentedLayout: WorkspaceLayout
  let networkModel: NetworkInspectorWebViewModel?
  let capturePaneWidth: CGFloat
  let titlebarHeight: CGFloat

  @Environment(AppSettings.self)
  private var settings

  var body: some View {
    ZStack {
      Color(nsColor: .windowBackgroundColor)
        .contentShape(Rectangle())
        .gesture(WindowDragGesture())

      if presentedLayout.showsCapture {
        HStack(spacing: 15) {
          captureControls()

          if !controller.isRecording, let progress = controller.captureProgressText {
            captureProgress(progress)
          }
        }
        .controlSize(.extraLarge)
        .snapOToolbarControlStyle()
        .position(x: capturePaneWidth / 2, y: controlsCenterY)
      }

      if presentedLayout == .both {
        HStack {
          captureToggle()
          Spacer()
        }
        .frame(height: Self.height)
        .padding(.leading, 12)
        .frame(maxWidth: .infinity)
        .offset(y: titlebarHeight / 2)
      }

      if presentedLayout.showsNetwork {
        HStack(spacing: 8) {
          if !presentedLayout.showsCapture {
            captureToggle()
          }
          if let networkModel {
            NetworkInspectorServerPicker(model: networkModel)
          }
          Spacer()
        }
        .frame(height: Self.height)
        .padding(.leading, presentedLayout.showsCapture ? capturePaneWidth + 12 : 12)
        .padding(.trailing, 64)
        .frame(maxWidth: .infinity)
        .offset(y: titlebarHeight / 2)
      }

      if presentedLayout.showsCapture {
        HStack {
          Spacer()
          networkToggle()
        }
        .frame(height: Self.height)
        .padding(.trailing, 12)
        .frame(maxWidth: .infinity)
        .offset(y: titlebarHeight / 2)
      }
    }
    .frame(height: titlebarHeight + Self.height)
    .overlay(alignment: .bottom) {
      Rectangle()
        .fill(Color(nsColor: .separatorColor).opacity(0.55))
        .frame(height: 0.5)
        .allowsHitTesting(false)
    }
  }

  private var controlsCenterY: CGFloat {
    titlebarHeight + (Self.height / 2)
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
          .font(CaptureToolbarStyle.iconFont)
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
        .font(CaptureToolbarStyle.iconFont)
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
    .snapOToolbarGroupStyle()
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
    .snapOToolbarGroupStyle()
  }

  private func toggleIcon(_ systemName: String) -> some View {
    Image(systemName: systemName)
      .font(CaptureToolbarStyle.iconFont)
      .frame(width: 34, height: 32)
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

private struct NetworkInspectorServerPicker: View {
  private enum Metrics {
    static let iconSize: CGFloat = 32
    static let statusSize: CGFloat = 8
    static let height: CGFloat = 48
  }

  @Bindable var model: NetworkInspectorWebViewModel
  @State private var isPresented = false

  var body: some View {
    Button {
      isPresented.toggle()
    } label: {
      HStack(spacing: 12) {
        if let server = model.selectedServer {
          NetworkInspectorServerIcon(
            server,
            size: Metrics.iconSize,
            statusSize: Metrics.statusSize
          )
        } else {
          NetworkInspectorServerIcon(
            server: nil,
            size: Metrics.iconSize,
            statusSize: Metrics.statusSize
          )
        }

        HStack(spacing: 6) {
          NetworkInspectorServerText(
            appName: model.selectedServer?.displayName ?? emptyTitle,
            deviceName: deviceTitle
          )

          Image(systemName: "chevron.down")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .rotationEffect(.degrees(isPresented ? 180 : 0))
        }
      }
      .frame(height: Metrics.height)
      .padding(.horizontal, 4)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .fixedSize()
    .popover(isPresented: $isPresented, arrowEdge: .bottom) {
      NetworkInspectorServerPickerPopover(model: model) {
        model.selectServer($0)
        isPresented = false
      }
    }
    .help("Select an app to inspect")
  }

  private var emptyTitle: String {
    model.servers.isEmpty ? "No Apps Found" : "Select an App"
  }

  private var deviceTitle: String {
    guard let title = model.selectedServer?.deviceDisplayTitle,
          !title.isEmpty
    else {
      return model.servers.isEmpty ? "No devices detected" : "Choose a device"
    }
    return title
  }
}

private struct NetworkInspectorServerPickerPopover: View {
  @Bindable var model: NetworkInspectorWebViewModel
  let selectServer: (NetworkInspectorServer) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Text("Detected servers")
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)

      if model.servers.isEmpty {
        Text("No Apps Found")
          .font(.system(size: 13))
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, 14)
          .padding(.bottom, 14)
      } else {
        ScrollView {
          LazyVStack(spacing: 0) {
            ForEach(model.servers, id: \.server) { server in
              NetworkInspectorServerPickerRow(server: server) {
                selectServer(server)
              }
            }
          }
          .padding(.horizontal, 6)
          .padding(.bottom, 6)
        }
        .frame(maxHeight: 320)
      }
    }
    .frame(width: 320)
  }
}

private struct NetworkInspectorServerPickerRow: View {
  let server: NetworkInspectorServer
  let select: () -> Void

  @State private var isHovering = false

  var body: some View {
    Button(action: select) {
      HStack(spacing: 12) {
        NetworkInspectorServerIcon(server, size: 32, statusSize: 8)
        NetworkInspectorServerText(
          appName: server.displayName,
          deviceName: server.deviceDisplayTitle
        )
      }
      .padding(.horizontal, 8)
      .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
      .contentShape(Rectangle())
      .background {
        if isHovering {
          RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(Color.primary.opacity(0.07))
        }
      }
    }
    .buttonStyle(.plain)
    .onHover { isHovering = $0 }
  }
}

private struct NetworkInspectorServerText: View {
  let appName: String
  let deviceName: String

  var body: some View {
    VStack(alignment: .leading, spacing: 1) {
      Text(appName)
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(.primary)
        .lineLimit(1)

      Text(deviceName)
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
  }
}

private struct NetworkInspectorServerIcon: View {
  let server: NetworkInspectorServer?
  let size: CGFloat
  let statusSize: CGFloat

  init(
    _ server: NetworkInspectorServer,
    size: CGFloat,
    statusSize: CGFloat
  ) {
    self.server = server
    self.size = size
    self.statusSize = statusSize
  }

  init(
    server: NetworkInspectorServer?,
    size: CGFloat,
    statusSize: CGFloat
  ) {
    self.server = server
    self.size = size
    self.statusSize = statusSize
  }

  var body: some View {
    ZStack(alignment: .bottomTrailing) {
      icon

      if let server {
        Circle()
          .fill(server.isConnected ? Color(nsColor: .systemGreen) : Color(nsColor: .secondaryLabelColor))
          .frame(width: statusSize, height: statusSize)
          .overlay {
            Circle()
              .stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 1)
          }
      }
    }
    .frame(width: size, height: size)
    .accessibilityHidden(true)
  }

  @ViewBuilder private var icon: some View {
    if let base64 = server?.appIconBase64,
       let data = Data(base64Encoded: base64),
       let image = NSImage(data: data) {
      Image(nsImage: image)
        .resizable()
        .aspectRatio(contentMode: .fill)
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
    } else {
      Circle()
        .fill(Color(nsColor: .unemphasizedSelectedContentBackgroundColor))
        .frame(width: size, height: size)
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
          .font(CaptureToolbarStyle.iconFont)
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
            .font(CaptureToolbarStyle.iconFont)
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
            .font(CaptureToolbarStyle.iconFont)
            .frame(width: 34, height: 32)
        }
        .help("Start Recording (⌘⇧R)")
        .disabled(!canStartRecordingNow)
      }

      Button {
        startLivePreview()
      } label: {
        Label("Live", systemImage: "play.circle")
          .font(CaptureToolbarStyle.iconFont)
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

private extension View {
  @ViewBuilder
  func snapOToolbarControlStyle() -> some View {
    if #available(macOS 26.0, *) {
      buttonStyle(.glass)
    } else {
      buttonStyle(.borderless)
    }
  }

  @ViewBuilder
  func snapOToolbarGroupStyle() -> some View {
    if #available(macOS 26.0, *) {
      buttonStyle(.borderless)
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .glassEffect(in: Capsule())
    } else {
      buttonStyle(.borderless)
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .background(Color(nsColor: .windowBackgroundColor), in: Capsule())
        .shadow(color: .black.opacity(0.18), radius: 3, y: 1)
    }
  }
}
