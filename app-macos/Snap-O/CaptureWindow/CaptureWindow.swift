import AppKit
import Observation
import SwiftUI

private struct CaptureWorkspaceMetrics: Equatable {
  let previewHeight: CGFloat
}

private struct WorkspacePanePresentation {
  let layout: WorkspaceLayout
  let captureWidth: CGFloat
  let toolWidth: CGFloat
  let captureVisibleWidth: CGFloat
  let toolVisibleWidth: CGFloat
  let transitioningPane: WorkspaceLayoutTransition.Pane?
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

struct CaptureWindow: View {
  @Environment(CaptureHistory.self)
  private var history
  @State private var historyProtectionID = UUID()
  @Environment(\.colorScheme)
  private var colorScheme

  @State private var controller: CaptureWindowController
  @State private var workspace: WorkspaceLayoutController
  @State private var toolSession: ToolSession
  @State private var presentedLayout: WorkspaceLayout
  @State private var layoutTransition: WorkspaceLayoutTransition?
  @State private var splitDragOrigin: CGFloat?

  init(
    captureServices: CaptureServices,
    deviceTracker: DeviceTracker,
    fileStore: FileStore,
    adbService: ADBService,
    initialWorkspace: WorkspaceLayoutSnapshot? = nil
  ) {
    let captureController = CaptureWindowController(
      captureServices: captureServices,
      deviceTracker: deviceTracker,
      fileStore: fileStore,
      adbService: adbService
    )
    let workspace = WorkspaceLayoutController(snapshot: initialWorkspace)
    _controller = State(initialValue: captureController)
    _workspace = State(initialValue: workspace)
    _toolSession = State(
      initialValue: ToolSession(
        adbService: adbService,
        deviceTracker: deviceTracker
      )
    )
    _presentedLayout = State(initialValue: workspace.layout)
    _layoutTransition = State(initialValue: nil)
  }

  var body: some View {
    @Bindable var controller = controller
    workspaceContent(controller: controller)
      .task {
        await controller.start()
      }
      .task(id: controller.mediaList.map(\.id)) {
        await history.repository.protect(Set(controller.mediaList.map(\.id)), owner: historyProtectionID)
        await synchronizeCaptureHistory()
      }
      .task(id: history.entries) {
        await synchronizeCaptureHistory()
      }
      .task(id: controller.currentCapture?.id) {
        if let captureID = controller.currentCapture?.id {
          await history.repository.recordCapturePaneSelection(captureID)
        }
      }
      .task(id: workspace.showsTool) {
        guard workspace.showsTool else {
          toolSession.model?.webContainer?.closeNativeColorPanel()
          // Hiding the pane is a layout change, not a session boundary. Preserve its streams and history until the window closes.
          return
        }
        toolSession.startIfNeeded()
      }
      .onDisappear {
        Task {
          await history.repository.protect([], owner: historyProtectionID)
          await controller.tearDown()
          await toolSession.stop()
        }
      }
      .focusedSceneValue(\.captureController, controller)
      .alert("Capture History", isPresented: Binding(
        get: { history.errorMessage != nil },
        set: { if !$0 { Task { await history.repository.clearError() } } }
      )) {
        Button("OK") { Task { await history.repository.clearError() } }
      } message: { Text(history.errorMessage ?? "") }
      .focusedSceneValue(\.workspaceController, workspace)
      .focusedSceneValue(\.toolHost, workspace.showsTool ? toolSession.model : nil)
      .sheet(isPresented: Binding(
        get: { toolSession.model?.isDevelopmentServerPresented == true },
        set: { toolSession.model?.isDevelopmentServerPresented = $0 }
      )) {
        if let model = toolSession.model { ToolDevelopmentServerSettings(model: model) }
      }
      .background(
        WindowSizingController(
          displayInfo: controller.displayInfoForSizing,
          layout: workspace.layout,
          capturePaneWidth: workspace.capturePaneWidth
        ) { width in
          workspace.resizeCapturePane(to: width)
          workspace.persistCapturePaneWidth()
        } presentationChanged: { event in
          switch event {
          case .transitionWillBegin(let transition):
            layoutTransition = transition
          case .layoutDidApply(let layout):
            presentedLayout = layout
            layoutTransition = nil
          }
        }
        .frame(width: 0, height: 0)
      )
      .background(
        WindowLevelController(
          shouldFloat: controller.isRecording
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

  private var captureHistoryEntry: CaptureHistoryEntry? {
    guard !controller.isLivePreviewActive, !controller.isRecording,
          let captureID = controller.currentCapture?.id else { return nil }
    return history.entries.first { $0.items.contains { $0.captureID == captureID } }
  }

  private func capturePaneTitle(for layout: WorkspaceLayout) -> CapturePaneTitle? {
    guard layout.showsCapture else { return nil }
    if layout.showsTool, controller.currentCapture == nil, !controller.isRecording { return nil }
    let entry = captureHistoryEntry
    return CapturePaneTitle(
      entry: entry,
      deviceTitle: controller.isLivePreviewActive ? nil : controller.currentCaptureDeviceTitle,
      fallbackTitle: controller.isLivePreviewActive
        ? controller.currentCaptureDeviceTitle ?? ""
        : controller.isRecording ? "Recording" : "Snap-O"
    ) { name in
      guard let entry else { return }
      Task { await history.repository.rename(entry.id, to: name) }
    }
  }

  private func navigationTitle(for layout: WorkspaceLayout) -> String {
    switch layout {
    case .capture:
      if let entry = captureHistoryEntry {
        return [entry.displayName, controller.currentCaptureDeviceTitle].compactMap(\.self).joined(separator: " — ")
      }
      return controller.navigationTitle
    case .tool, .both:
      guard let model = toolSession.model,
            let toolName = model.selectedToolApp?.tools.first(where: {
              $0.kind == model.preferredPluginID
            })?.name.trimmingCharacters(in: .whitespacesAndNewlines),
            !toolName.isEmpty else { return "Snap-O" }
      return toolName
    }
  }

  private func workspaceContent(controller: CaptureWindowController) -> some View {
    GeometryReader { geometry in
      let titlebarHeight = WindowChromeMetrics.titlebarHeight
      let displayedLayout = layoutTransition == nil ? presentedLayout : .both
      let captureWidth = displayedLayout.showsCapture
        ? capturePaneWidth(
          totalWidth: geometry.size.width,
          layout: displayedLayout,
          aspectRatio: controller.displayInfoForSizing?.aspectRatio
        )
        : 0
      let toolWidth = displayedLayout.showsTool
        ? toolPaneWidth(
          totalWidth: geometry.size.width,
          captureWidth: captureWidth,
          layout: displayedLayout
        )
        : 0
      let captureVisibleWidth = visibleCapturePaneWidth(
        totalWidth: geometry.size.width,
        captureWidth: captureWidth
      )
      let toolVisibleWidth = visibleToolPaneWidth(
        totalWidth: geometry.size.width,
        toolWidth: toolWidth
      )
      let dividerX = workspaceDividerX(
        totalWidth: geometry.size.width,
        captureWidth: captureWidth,
        toolWidth: toolWidth,
        layout: displayedLayout
      )
      let panePresentation = WorkspacePanePresentation(
        layout: displayedLayout,
        captureWidth: captureWidth,
        toolWidth: toolWidth,
        captureVisibleWidth: captureVisibleWidth,
        toolVisibleWidth: toolVisibleWidth,
        transitioningPane: layoutTransition?.pane
      )

      VStack(spacing: 0) {
        CaptureToolbar(
          controller: controller,
          workspace: workspace,
          presentedLayout: displayedLayout,
          toolModel: toolSession.model,
          capturePaneWidth: captureWidth,
          toolPaneWidth: toolWidth,
          capturePaneVisibleWidth: captureVisibleWidth,
          toolPaneVisibleWidth: toolVisibleWidth,
          transitioningPane: layoutTransition?.pane,
          titlebarHeight: titlebarHeight
        )

        captureWorkspace(
          controller: controller,
          presentation: panePresentation
        )
      }
      .background(toolSidebarBackground, ignoresSafeAreaEdges: [])
      .overlayPreferenceValue(CaptureWorkspaceMetricsKey.self) { metrics in
        if displayedLayout == .both,
           layoutTransition == nil,
           let metrics {
          workspaceSplitter(
            totalWidth: geometry.size.width,
            previewHeight: metrics.previewHeight,
            aspectRatio: controller.displayInfoForSizing?.aspectRatio
          )
          .frame(width: 1, height: metrics.previewHeight)
          .offset(x: captureWidth - 0.5)
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        }
      }
      .background(
        WindowChromeController(
          title: navigationTitle(for: displayedLayout),
          dividerX: dividerX,
          captureTitle: capturePaneTitle(for: displayedLayout)
        )
        .frame(width: 0, height: 0)
      )
      .ignoresSafeArea(.container, edges: .top)
    }
  }

  private func capturePaneWidth(
    totalWidth: CGFloat,
    layout: WorkspaceLayout,
    aspectRatio: CGFloat?
  ) -> CGFloat {
    if let layoutTransition {
      return layoutTransition.capturePaneWidth(windowWidth: totalWidth)
    }
    return layout.showsTool
      ? constrainedCaptureWidth(totalWidth: totalWidth, aspectRatio: aspectRatio)
      : totalWidth
  }

  private func toolPaneWidth(
    totalWidth: CGFloat,
    captureWidth: CGFloat,
    layout: WorkspaceLayout
  ) -> CGFloat {
    if let layoutTransition {
      return layoutTransition.toolPaneWidth(windowWidth: totalWidth)
    }
    return layout.showsCapture
      ? max(totalWidth - captureWidth - 1, 0)
      : totalWidth
  }

  private func workspaceDividerX(
    totalWidth: CGFloat,
    captureWidth: CGFloat,
    toolWidth: CGFloat,
    layout: WorkspaceLayout
  ) -> CGFloat? {
    guard layout == .both else { return nil }
    if layoutTransition?.pane == .capture {
      return totalWidth - toolWidth
    }
    return captureWidth
  }

  private func visibleCapturePaneWidth(
    totalWidth: CGFloat,
    captureWidth: CGFloat
  ) -> CGFloat {
    guard let layoutTransition, layoutTransition.pane == .capture else {
      return captureWidth
    }
    let progress = layoutTransition.progress(windowWidth: totalWidth)
    let visibility = layoutTransition.toLayout.showsCapture ? progress : 1 - progress
    return captureWidth * visibility
  }

  private func visibleToolPaneWidth(
    totalWidth: CGFloat,
    toolWidth: CGFloat
  ) -> CGFloat {
    guard let layoutTransition, layoutTransition.pane == .tool else {
      return toolWidth
    }
    let progress = layoutTransition.progress(windowWidth: totalWidth)
    let visibility = layoutTransition.toLayout.showsTool ? progress : 1 - progress
    return toolWidth * visibility
  }

  private func captureWorkspace(
    controller: CaptureWindowController,
    presentation: WorkspacePanePresentation
  ) -> some View {
    GeometryReader { geometry in
      let previewHeight = geometry.size.height

      ZStack(alignment: .topLeading) {
        if presentation.layout.showsCapture {
          capturePane(controller: controller, layout: presentation.layout)
            .frame(width: presentation.captureWidth, height: previewHeight)
            .frame(
              width: presentation.captureVisibleWidth,
              height: previewHeight,
              alignment: .leading
            )
            .clipped()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .zIndex(presentation.transitioningPane == .tool ? 1 : 0)
        }

        if presentation.layout.showsTool {
          Group {
            if let toolModel = toolSession.model {
              ToolWebView(model: toolModel)
                .overlay {
                  if let compatibility = toolModel.compatibilityExplanation {
                    VStack(alignment: .leading, spacing: 12) {
                      Image(systemName: compatibility.isUnsupported ? "exclamationmark.triangle" : "wifi.exclamationmark")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                      Text(compatibility.title(for: toolModel.preferredPluginID) ?? "Tool unavailable").font(.headline)
                      Text(compatibility.explanation ?? "")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                      if let version = compatibility.versionDetail {
                        Text(version).font(.caption).foregroundStyle(.tertiary)
                      }
                    }
                    .frame(maxWidth: 440, alignment: .leading)
                    .padding(24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(nsColor: .textBackgroundColor))
                  } else if toolModel.isWaiting || toolModel.selectedTool == nil {
                    VStack(spacing: 12) {
                      if let app = toolModel.selectedToolApp {
                        Text("Waiting for \(app.name)")
                          .foregroundStyle(.secondary)
                      } else {
                        Text("Waiting for app")
                          .foregroundStyle(.secondary)
                      }
                      if let launch = toolModel.appLaunch {
                        Button(launch.pending ? "Opening…" : "Open App") { toolModel.openSelectedApp() }
                          .disabled(launch.pending)
                        if let error = launch.error { Text(error).foregroundStyle(.red) }
                      }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(nsColor: .textBackgroundColor))
                  } else if let error = toolModel.frontendError {
                    VStack(spacing: 12) {
                      Text(error).foregroundStyle(.secondary).multilineTextAlignment(.center)
                      Button("Retry") { toolModel.retryFrontend() }
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(nsColor: .textBackgroundColor))
                  } else if !toolModel.isPageReady {
                    let toolName = toolModel.selectedToolApp?.tools.first {
                      $0.kind == toolModel.selectedTool?.kind
                    }?.displayName ?? "tool"
                    ProgressView("Loading \(toolName)…")
                      .frame(maxWidth: .infinity, maxHeight: .infinity)
                      .background(Color(nsColor: .textBackgroundColor))
                  }
                }
            } else {
              ProgressView()
            }
          }
          .frame(width: presentation.toolWidth, height: previewHeight)
          .background(Color(nsColor: .windowBackgroundColor))
          .frame(
            width: presentation.toolVisibleWidth,
            height: previewHeight,
            alignment: .trailing
          )
          .clipped()
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
          .zIndex(presentation.transitioningPane == .capture ? 1 : 0)
        }

        if presentation.layout == .both, presentation.transitioningPane != .capture {
          LinearGradient(
            colors: [.black.opacity(0.04), .clear],
            startPoint: .leading,
            endPoint: .trailing
          )
          .frame(width: 8, height: previewHeight)
          .offset(x: presentation.captureWidth)
          .zIndex(2)
          .allowsHitTesting(false)
        }
      }
      .preference(
        key: CaptureWorkspaceMetricsKey.self,
        value: CaptureWorkspaceMetrics(previewHeight: previewHeight)
      )
    }
  }

  private func capturePane(
    controller: CaptureWindowController,
    layout: WorkspaceLayout
  ) -> some View {
    CaptureSurfaceView(aspectRatio: layout.showsTool ? controller.displayInfoForSizing?.aspectRatio : nil) {
      captureContent(controller: controller)
    }
    .environment(\.captureImageCopied, controller.imageCopied)
    .overlay {
      CaptureCopyConfirmation(copyID: controller.imageCopyID)
    }
    .background(captureAreaBackground)
  }

  private var captureAreaBackground: Color {
    Color(nsColor: .windowBackgroundColor)
  }

  private var captureLetterboxBackground: Color {
    Color(nsColor: .unemphasizedSelectedContentBackgroundColor)
  }

  private var toolSidebarBackground: Color {
    if colorScheme == .dark {
      Color(red: 42.0 / 255.0, green: 42.0 / 255.0, blue: 42.0 / 255.0)
    } else {
      Color(red: 244.0 / 255.0, green: 244.0 / 255.0, blue: 244.0 / 255.0)
    }
  }

  private func captureContent(controller: CaptureWindowController) -> some View {
    ZStack {
      captureLetterboxBackground

      if controller.currentCapture != nil {
        CaptureSnapshotView(
          controller: controller.snapshotController,
          fileStore: controller.fileStore,
          livePreviewHost: controller
        )
      } else if controller.isLivePreviewActive, controller.hasDevices {
        WaitingForDeviceView(isDeviceListInitialized: true, deviceMessage: "Connecting to device")
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

  private func synchronizeCaptureHistory() async {
    // Fetch current metadata so a newly displayed capture never uses an older UI snapshot.
    let snapshot = await history.repository.currentSnapshot()
    guard !Task.isCancelled else { return }
    controller.synchronizeCaptureHistory(
      availableCaptureIDs: Set(snapshot.entries.flatMap { $0.items.compactMap(\.captureID) }),
      root: history.repository.root
    )
  }

  private func handle(_ command: SnapOCommand, controller: CaptureWindowController) async {
    switch command {
    case .record:
      await controller.startRecording()
    case .capture:
      await controller.captureScreenshots()
    case .livepreview:
      guard controller.canStartLivePreviewNow else { return }
      await controller.startLivePreview()
    }
  }
}
