import AppKit
import Observation
import SwiftUI

private enum CaptureToolbarStyle {
  static let iconFont = Font.system(size: 17, weight: .medium)
  static let singleControlSize: CGFloat = 36
}

struct CaptureToolbar: View {
  static let height: CGFloat = 52

  @Bindable var controller: CaptureWindowController
  @Bindable var workspace: WorkspaceLayoutController
  let presentedLayout: WorkspaceLayout
  let networkModel: NetworkInspectorWebViewModel?
  let capturePaneWidth: CGFloat
  let titlebarHeight: CGFloat

  @Environment(\.colorScheme)
  private var colorScheme
  @Environment(AppSettings.self)
  private var settings
  @State private var isNetworkSearchPresented = false

  var body: some View {
    ZStack {
      chromeBackground

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
            NetworkInspectorToolbarControls(
              model: networkModel,
              isSearchPresented: $isNetworkSearchPresented
            )
            NetworkInspectorServerPicker(model: networkModel)
              .padding(.leading, 4)
          }
          Spacer()
          if let networkModel {
            NetworkInspectorExportMenu(model: networkModel)
          }
        }
        .frame(height: Self.height)
        .padding(.leading, presentedLayout.showsCapture ? capturePaneWidth + 12 : 12)
        .padding(.trailing, presentedLayout.showsCapture ? 64 : 12)
        .frame(maxWidth: .infinity)
        .offset(y: titlebarHeight / 2)
        .animation(.easeOut(duration: 0.16), value: isNetworkSearchPresented)
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
        .fill(Color(nsColor: .separatorColor))
        .frame(height: 0.5)
        .allowsHitTesting(false)
    }
  }

  private var controlsCenterY: CGFloat {
    titlebarHeight + (Self.height / 2)
  }

  private var chromeBackground: some View {
    GeometryReader { geometry in
      HStack(spacing: 0) {
        if presentedLayout.showsCapture {
          captureChromeBackground
            .frame(width: presentedLayout.showsNetwork ? capturePaneWidth : geometry.size.width)
        }

        if presentedLayout.showsNetwork {
          Color(nsColor: .windowBackgroundColor)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
      .contentShape(Rectangle())
      .gesture(WindowDragGesture())
    }
  }

  private var captureChromeBackground: Color {
    if colorScheme == .dark {
      Color(red: 42.0 / 255.0, green: 42.0 / 255.0, blue: 42.0 / 255.0)
    } else {
      Color(red: 244.0 / 255.0, green: 244.0 / 255.0, blue: 244.0 / 255.0)
    }
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
    .snapOToolbarSingleControlStyle()
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
  }

  private func toggleIcon(_ systemName: String) -> some View {
    Image(systemName: systemName)
      .font(CaptureToolbarStyle.iconFont)
      .frame(
        width: CaptureToolbarStyle.singleControlSize,
        height: CaptureToolbarStyle.singleControlSize
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

private struct NetworkInspectorExportMenu: View {
  @Bindable var model: NetworkInspectorWebViewModel
  @State private var menuPresenter = NetworkInspectorExportMenuPresenter()

  var body: some View {
    Button {
      menuPresenter.present(model: model)
    } label: {
      Image(systemName: "square.and.arrow.up")
        .font(CaptureToolbarStyle.iconFont)
        .frame(
          width: CaptureToolbarStyle.singleControlSize,
          height: CaptureToolbarStyle.singleControlSize
        )
        .accessibilityLabel("Export")
        .background {
          NetworkInspectorExportMenuAnchor(presenter: menuPresenter)
            .allowsHitTesting(false)
        }
    }
    .help("Export requests")
    .disabled(!model.isPageReady || (model.selectedRecordKind == nil && !model.hasVisibleRecords))
    .controlSize(.extraLarge)
    .snapOToolbarSingleControlStyle()
  }
}

private struct NetworkInspectorExportMenuAnchor: NSViewRepresentable {
  let presenter: NetworkInspectorExportMenuPresenter

  func makeNSView(context: Context) -> NSView {
    let view = NSView()
    presenter.anchorView = view
    return view
  }

  func updateNSView(_ nsView: NSView, context: Context) {
    presenter.anchorView = nsView
  }
}

@MainActor
private final class NetworkInspectorExportMenuPresenter: NSObject {
  weak var anchorView: NSView?
  private var model: NetworkInspectorWebViewModel?

  func present(model: NetworkInspectorWebViewModel) {
    guard let anchorView, anchorView.window != nil else { return }
    self.model = model

    let menu = NSMenu()
    menu.autoenablesItems = false
    menu.addItem(
      menuItem(
        title: "Export HAR (sanitized)…",
        systemImage: "doc.badge.arrow.up",
        action: #selector(exportHar),
        isEnabled: model.hasVisibleRecords
      )
    )
    menu.addItem(.separator())
    menu.addItem(
      menuItem(
        title: "Copy URL",
        systemImage: "link",
        action: #selector(copyURL),
        isEnabled: model.selectedRecordKind != nil
      )
    )
    menu.addItem(
      menuItem(
        title: "Copy as CURL",
        systemImage: "terminal",
        action: #selector(copyCurl),
        isEnabled: model.selectedRecordKind == "request"
      )
    )

    menu.popUp(positioning: nil, at: NSPoint(x: 0, y: 0), in: anchorView)
    self.model = nil
  }

  private func menuItem(
    title: String,
    systemImage: String,
    action: Selector,
    isEnabled: Bool
  ) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
    item.target = self
    item.image = NSImage(systemSymbolName: systemImage, accessibilityDescription: nil)
    item.isEnabled = isEnabled
    return item
  }

  @objc
  private func exportHar() {
    model?.exportVisibleRecordsAsHar()
  }

  @objc
  private func copyURL() {
    model?.copySelectedURL()
  }

  @objc
  private func copyCurl() {
    model?.copySelectedCurl()
  }
}

private struct NetworkInspectorToolbarControls: View {
  @Bindable var model: NetworkInspectorWebViewModel
  @Binding var isSearchPresented: Bool

  private var sortHelp: String {
    model.sortNewestFirst
      ? "Sorted newest first. Show oldest first"
      : "Sorted oldest first. Show newest first"
  }

  var body: some View {
    HStack(spacing: 8) {
      HStack(spacing: 0) {
        Button {
          model.clearCompletedRecords()
        } label: {
          Label("Clear Completed Requests", systemImage: "trash")
            .labelStyle(.iconOnly)
            .font(.system(size: 15, weight: .medium))
            .frame(width: 34, height: 32)
        }
        .help("Clear completed requests")
        .disabled(!model.hasClearableItems)

        Button {
          model.setSortNewestFirst(!model.sortNewestFirst)
        } label: {
          Label(
            model.sortNewestFirst ? "Newest First" : "Oldest First",
            systemImage: model.sortNewestFirst ? "arrow.down" : "arrow.up"
          )
          .labelStyle(.iconOnly)
          .font(.system(size: 15, weight: .medium))
          .frame(width: 34, height: 32)
        }
        .help(sortHelp)

        if !isSearchPresented {
          Button {
            isSearchPresented = true
          } label: {
            Label("Filter Requests", systemImage: "magnifyingglass")
              .labelStyle(.iconOnly)
              .font(.system(size: 15, weight: .medium))
              .frame(width: 34, height: 32)
          }
          .help("Filter requests (⌘F)")
          .keyboardShortcut("f", modifiers: .command)
          .transition(.opacity)
        }
      }
      .snapOToolbarGroupStyle()

      if isSearchPresented {
        NetworkInspectorSearchField(
          text: Binding(
            get: { model.searchText },
            set: { model.setSearchText($0) }
          )
        ) {
          isSearchPresented = false
        }
        .transition(
          .modifier(
            active: NetworkInspectorSearchTransition(progress: 0),
            identity: NetworkInspectorSearchTransition(progress: 1)
          )
        )
      }
    }
    .disabled(!model.isPageReady)
    .onAppear {
      if !model.searchText.isEmpty {
        isSearchPresented = true
      }
    }
    .onChange(of: model.searchText) {
      if !model.searchText.isEmpty {
        isSearchPresented = true
      }
    }
  }
}

private struct NetworkInspectorSearchTransition: ViewModifier {
  let progress: CGFloat

  func body(content: Content) -> some View {
    content
      .frame(width: 220 * progress, height: 28, alignment: .leading)
      .clipped()
      .opacity(progress)
  }
}

private struct NetworkInspectorSearchField: NSViewRepresentable {
  @Binding var text: String
  let dismiss: () -> Void

  func makeCoordinator() -> Coordinator {
    Coordinator(text: $text, dismiss: dismiss)
  }

  func makeNSView(context: Context) -> FocusedSearchField {
    let searchField = FocusedSearchField(string: text)
    searchField.placeholderString = "Filter requests"
    searchField.sendsSearchStringImmediately = true
    searchField.sendsWholeSearchString = true
    searchField.delegate = context.coordinator
    searchField.bezelStyle = .roundedBezel
    searchField.controlSize = .large
    return searchField
  }

  func updateNSView(_ nsView: FocusedSearchField, context: Context) {
    context.coordinator.text = $text
    context.coordinator.dismiss = dismiss
    if nsView.stringValue != text {
      nsView.stringValue = text
    }
  }

  final class Coordinator: NSObject, NSSearchFieldDelegate {
    var text: Binding<String>
    var dismiss: () -> Void

    init(text: Binding<String>, dismiss: @escaping () -> Void) {
      self.text = text
      self.dismiss = dismiss
    }

    func controlTextDidChange(_ notification: Notification) {
      guard let field = notification.object as? NSSearchField else { return }
      text.wrappedValue = field.stringValue
    }

    func control(
      _ control: NSControl,
      textView: NSTextView,
      doCommandBy commandSelector: Selector
    ) -> Bool {
      guard commandSelector == #selector(NSResponder.cancelOperation(_:)),
            let field = control as? NSSearchField
      else {
        return false
      }

      if field.stringValue.isEmpty {
        dismiss()
      } else {
        field.stringValue = ""
        text.wrappedValue = ""
      }
      return true
    }
  }
}

private final class FocusedSearchField: NSSearchField {
  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    guard window != nil else { return }
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      window?.makeFirstResponder(self)
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
  func snapOToolbarSingleControlStyle() -> some View {
    if #available(macOS 26.0, *) {
      buttonStyle(.borderless)
        .glassEffect(in: Circle())
    } else {
      buttonStyle(.borderless)
        .background(Color(nsColor: .windowBackgroundColor), in: Circle())
        .shadow(color: .black.opacity(0.18), radius: 3, y: 1)
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
