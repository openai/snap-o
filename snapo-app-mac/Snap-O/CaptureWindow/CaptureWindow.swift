import AppKit
import Combine
import Observation
import SwiftUI

private struct CaptureControllerKey: FocusedValueKey {
  typealias Value = CaptureWindowController
}

private struct WorkspaceControllerKey: FocusedValueKey {
  typealias Value = WorkspaceLayoutController
}

private struct CaptureWorkspaceMetrics: Equatable {
  let previewHeight: CGFloat
}

private struct CaptureWorkspaceMetricsKey: PreferenceKey {
  static let defaultValue: CaptureWorkspaceMetrics? = nil

  static func reduce(
    value: inout CaptureWorkspaceMetrics?,
    nextValue: () -> CaptureWorkspaceMetrics?
  ) {
    value = nextValue() ?? value
  }
}

extension FocusedValues {
  var captureController: CaptureWindowController? {
    get { self[CaptureControllerKey.self] }
    set { self[CaptureControllerKey.self] = newValue }
  }

  var workspaceController: WorkspaceLayoutController? {
    get { self[WorkspaceControllerKey.self] }
    set { self[WorkspaceControllerKey.self] = newValue }
  }
}

struct CaptureWindow: View {
  @Environment(\.colorScheme)
  private var colorScheme

  @State private var controller: CaptureWindowController
  @State private var workspace: WorkspaceLayoutController
  @State private var networkSession: NetworkInspectorSession
  @State private var presentedLayout: WorkspaceLayout
  @State private var splitDragOrigin: CGFloat?

  init(
    captureService: CaptureService,
    deviceTracker: DeviceTracker,
    fileStore: FileStore,
    adbService: ADBService,
    initialWorkspace: WorkspaceLayoutSnapshot? = nil
  ) {
    let captureController = CaptureWindowController(
      captureService: captureService,
      deviceTracker: deviceTracker,
      fileStore: fileStore,
      adbService: adbService
    )
    let workspace = WorkspaceLayoutController(snapshot: initialWorkspace)
    _controller = State(initialValue: captureController)
    _workspace = State(initialValue: workspace)
    _networkSession = State(initialValue: NetworkInspectorSession(deviceTracker: deviceTracker))
    _presentedLayout = State(initialValue: workspace.layout)
  }

  var body: some View {
    @Bindable var controller = controller
    workspaceContent(controller: controller)
      .task {
        await controller.start()
      }
      .task(id: workspace.showsNetwork) {
        guard workspace.showsNetwork else {
          // Hiding the pane is a layout change, not a session boundary. Preserve its streams and history until the window closes.
          return
        }
        networkSession.startIfNeeded()
      }
      .onDisappear {
        controller.tearDown()
        Task { await networkSession.stop() }
      }
      .focusedSceneValue(\.captureController, controller)
      .focusedSceneValue(\.workspaceController, workspace)
      .background(
        WindowSizingController(
          displayInfo: controller.displayInfoForSizing,
          layout: workspace.layout,
          capturePaneWidth: workspace.capturePaneWidth
        ) { width in
          workspace.resizeCapturePane(to: width)
          workspace.persistCapturePaneWidth()
        } layoutWillApply: { layout in
          presentedLayout = layout
        }
        .frame(width: 0, height: 0)
      )
      .background(
        WindowLevelController(
          shouldFloat: controller.isRecording || controller.isLivePreviewActive
        )
        .frame(width: 0, height: 0)
      )
      .background(
        WindowCommandRegistration { command in
          workspace.revealCapture()
          Task { await handle(command, controller: controller) }
        }
        .frame(width: 0, height: 0)
      )
  }

  private var navigationTitle: String {
    switch presentedLayout {
    case .capture:
      controller.navigationTitle
    case .network:
      "Snap-O"
    case .both:
      "Snap-O"
    }
  }

  private func workspaceContent(controller: CaptureWindowController) -> some View {
    GeometryReader { geometry in
      let titlebarHeight = WindowChromeMetrics.titlebarHeight
      let captureWidth = presentedLayout.showsCapture
        ? capturePaneWidth(
          totalWidth: geometry.size.width,
          aspectRatio: controller.displayInfoForSizing?.aspectRatio
        )
        : 0

      VStack(spacing: 0) {
        CaptureToolbar(
          controller: controller,
          workspace: workspace,
          presentedLayout: presentedLayout,
          networkModel: networkSession.model,
          capturePaneWidth: captureWidth,
          titlebarHeight: titlebarHeight
        )

        captureWorkspace(
          controller: controller,
          captureWidth: captureWidth
        )
      }
      .background(networkSidebarBackground, ignoresSafeAreaEdges: [])
      .overlayPreferenceValue(CaptureWorkspaceMetricsKey.self) { metrics in
        if presentedLayout == .both,
           let metrics {
          workspaceSplitter(
            totalWidth: geometry.size.width,
            previewHeight: metrics.previewHeight,
            aspectRatio: controller.displayInfoForSizing?.aspectRatio
          )
          .frame(width: 1)
          .frame(maxHeight: .infinity)
          .offset(x: captureWidth - 0.5)
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
      }
      .background(
        WindowChromeController(
          title: navigationTitle,
          dividerX: presentedLayout == .both ? captureWidth : nil
        )
        .frame(width: 0, height: 0)
      )
      .ignoresSafeArea(.container, edges: .top)
    }
  }

  private func capturePaneWidth(totalWidth: CGFloat, aspectRatio: CGFloat?) -> CGFloat {
    presentedLayout.showsNetwork
      ? constrainedCaptureWidth(totalWidth: totalWidth, aspectRatio: aspectRatio)
      : totalWidth
  }

  private func captureWorkspace(
    controller: CaptureWindowController,
    captureWidth: CGFloat
  ) -> some View {
    GeometryReader { geometry in
      let previewHeight = geometry.size.height

      ZStack(alignment: .topLeading) {
        HStack(alignment: .top, spacing: 0) {
          if presentedLayout.showsCapture {
            capturePane(controller: controller)
              .frame(width: presentedLayout.showsNetwork ? captureWidth : geometry.size.width)
              .frame(height: previewHeight)
          }

          if presentedLayout.showsNetwork {
            if let networkModel = networkSession.model {
              NetworkInspectorWebView(model: networkModel)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .windowBackgroundColor))
            } else {
              ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .windowBackgroundColor))
            }
          }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

        if presentedLayout == .both {
          LinearGradient(
            colors: [.black.opacity(0.04), .clear],
            startPoint: .leading,
            endPoint: .trailing
          )
          .frame(width: 8, height: previewHeight)
          .offset(x: captureWidth)
          .allowsHitTesting(false)
        }
      }
      .preference(
        key: CaptureWorkspaceMetricsKey.self,
        value: CaptureWorkspaceMetrics(previewHeight: previewHeight)
      )
    }
  }

  private func capturePane(controller: CaptureWindowController) -> some View {
    captureSurface(controller: controller)
      .background(captureAreaBackground)
  }

  private func captureSurface(controller: CaptureWindowController) -> some View {
    Group {
      if presentedLayout.showsNetwork, let displayInfo = controller.displayInfoForSizing {
        ZStack {
          captureLetterboxBackground
          captureContent(controller: controller)
            .aspectRatio(displayInfo.aspectRatio, contentMode: .fit)
        }
      } else {
        captureContent(controller: controller)
      }
    }
  }

  private var captureAreaBackground: Color {
    Color(nsColor: .windowBackgroundColor)
  }

  private var captureLetterboxBackground: Color {
    Color(nsColor: .unemphasizedSelectedContentBackgroundColor)
  }

  private var networkSidebarBackground: Color {
    if colorScheme == .dark {
      Color(red: 42.0 / 255.0, green: 42.0 / 255.0, blue: 42.0 / 255.0)
    } else {
      Color(red: 244.0 / 255.0, green: 244.0 / 255.0, blue: 244.0 / 255.0)
    }
  }

  private func captureContent(controller: CaptureWindowController) -> some View {
    ZStack {
      Color.black

      if controller.currentCapture != nil {
        CaptureSnapshotView(
          controller: controller.snapshotController,
          fileStore: controller.fileStore,
          livePreviewHost: controller
        )
      } else if controller.isDeviceListInitialized {
        IdleOverlayView(
          hasDevices: controller.hasDevices,
          isDeviceListInitialized: controller.isDeviceListInitialized,
          isProcessing: controller.isProcessing,
          isRecording: controller.isRecording,
          stopRecording: { Task { await controller.stopRecording() } },
          lastError: controller.lastError
        )
      } else {
        WaitingForDeviceView(isDeviceListInitialized: controller.isDeviceListInitialized)
      }

      if controller.currentCapture != nil, !controller.screenshotFailures.isEmpty {
        VStack {
          ScreenshotFailureBanner(
            failures: controller.screenshotFailures,
            successfulCaptureCount: controller.mediaList.count,
            onDismiss: controller.dismissScreenshotFailures
          )
          Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
      }
    }
    .clipped()
  }

  private func workspaceSplitter(
    totalWidth: CGFloat,
    previewHeight: CGFloat,
    aspectRatio: CGFloat?
  ) -> some View {
    Color.clear
      .frame(width: 1)
      .overlay {
        WorkspaceSplitterArea(
          dragChanged: { translation in
            if splitDragOrigin == nil {
              splitDragOrigin = workspace.capturePaneWidth
            }
            let origin = splitDragOrigin ?? workspace.capturePaneWidth
            workspace.resizeCapturePane(
              to: constrainedCaptureWidth(
                origin + translation,
                totalWidth: totalWidth,
                aspectRatio: aspectRatio
              )
            )
          },
          dragEnded: {
            splitDragOrigin = nil
            workspace.persistCapturePaneWidth()
          },
          doubleClicked: {
            guard let aspectRatio, aspectRatio > 0 else { return }
            workspace.resizeCapturePane(
              to: constrainedCaptureWidth(
                previewHeight * aspectRatio,
                totalWidth: totalWidth,
                aspectRatio: aspectRatio
              )
            )
            workspace.persistCapturePaneWidth()
          }
        )
        .frame(width: 9)
      }
  }

  private func constrainedCaptureWidth(
    totalWidth: CGFloat,
    aspectRatio: CGFloat?
  ) -> CGFloat {
    constrainedCaptureWidth(
      workspace.capturePaneWidth,
      totalWidth: totalWidth,
      aspectRatio: aspectRatio
    )
  }

  private func constrainedCaptureWidth(
    _ width: CGFloat,
    totalWidth: CGFloat,
    aspectRatio: CGFloat?
  ) -> CGFloat {
    let minimumWidth = WindowSizingController.minimumCapturePaneWidth(
      aspectRatio: aspectRatio
    )
    return min(
      max(width, minimumWidth),
      max(totalWidth - 720, minimumWidth)
    )
  }

  private func handle(_ command: SnapOCommand, controller: CaptureWindowController) async {
    switch command {
    case .record:
      guard controller.canStartRecordingNow else { return }
      await controller.startRecording()
    case .capture:
      guard controller.canCaptureNow else { return }
      await controller.captureScreenshots()
    case .livepreview:
      guard controller.canStartLivePreviewNow else { return }
      await controller.startLivePreview()
    }
  }
}

private struct ScreenshotFailureBanner: View {
  let failures: [CaptureFailure]
  let successfulCaptureCount: Int
  let onDismiss: () -> Void

  private var title: String {
    let total = successfulCaptureCount + failures.count
    if total == 1 { return "Screenshot failed" }
    return "\(failures.count) of \(total) screenshots failed"
  }

  var body: some View {
    HStack(alignment: .top, spacing: 8) {
      Image(systemName: "exclamationmark.triangle.fill")
        .font(.system(size: 14))
        .foregroundStyle(.orange)
        .padding(.top, 1)

      VStack(alignment: .leading, spacing: 3) {
        Text(title)
          .font(.subheadline.weight(.semibold))

        ForEach(failures, id: \.device.id) { failure in
          Text(failure.message)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }

      Spacer(minLength: 0)

      Button(action: onDismiss) {
        Image(systemName: "xmark.circle.fill")
          .font(.system(size: 14))
          .symbolRenderingMode(.hierarchical)
          .frame(width: 18, height: 18)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .foregroundStyle(.secondary)
      .help("Dismiss")
    }
    .padding(12)
    .frame(maxWidth: 460, alignment: .leading)
    .background(
      Color(nsColor: .controlBackgroundColor),
      in: RoundedRectangle(cornerRadius: 8, style: .continuous)
    )
    .overlay {
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
    }
    .shadow(color: .black.opacity(0.18), radius: 5, y: 2)
  }
}

private struct WorkspaceSplitterArea: NSViewRepresentable {
  let dragChanged: (CGFloat) -> Void
  let dragEnded: () -> Void
  let doubleClicked: () -> Void

  func makeNSView(context: Context) -> WorkspaceSplitterNSView {
    WorkspaceSplitterNSView(
      dragChanged: dragChanged,
      dragEnded: dragEnded,
      doubleClicked: doubleClicked
    )
  }

  func updateNSView(_ nsView: WorkspaceSplitterNSView, context: Context) {
    nsView.dragChanged = dragChanged
    nsView.dragEnded = dragEnded
    nsView.doubleClicked = doubleClicked
    nsView.window?.invalidateCursorRects(for: nsView)
  }
}

private final class WorkspaceSplitterNSView: NSView {
  var dragChanged: (CGFloat) -> Void
  var dragEnded: () -> Void
  var doubleClicked: () -> Void

  private var dragOriginX: CGFloat?

  init(
    dragChanged: @escaping (CGFloat) -> Void,
    dragEnded: @escaping () -> Void,
    doubleClicked: @escaping () -> Void
  ) {
    self.dragChanged = dragChanged
    self.dragEnded = dragEnded
    self.doubleClicked = doubleClicked
    super.init(frame: .zero)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    nil
  }

  override func resetCursorRects() {
    super.resetCursorRects()
    addCursorRect(bounds, cursor: .resizeLeftRight)
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    window?.invalidateCursorRects(for: self)
  }

  override var mouseDownCanMoveWindow: Bool {
    false
  }

  override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
    true
  }

  override func mouseDown(with event: NSEvent) {
    if event.clickCount == 2 {
      dragOriginX = nil
      doubleClicked()
    } else {
      dragOriginX = event.locationInWindow.x
    }
  }

  override func mouseDragged(with event: NSEvent) {
    guard let dragOriginX else { return }
    dragChanged(event.locationInWindow.x - dragOriginX)
  }

  override func mouseUp(with event: NSEvent) {
    guard dragOriginX != nil else { return }
    dragOriginX = nil
    dragEnded()
  }
}
