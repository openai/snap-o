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
  @Environment(AppSettings.self)
  private var settings
  @Environment(\.openWindow)
  private var openWindow
  @Environment(CaptureHistory.self)
  private var history
  @Environment(\.colorScheme)
  private var colorScheme
  @Environment(\.accessibilityReduceMotion)
  private var reduceMotion

  private let deviceManager: DeviceManager
  @State private var session: CaptureWindowSession
  private var controller: CapturePaneSession {
    session.capture
  }

  private var toolSession: ToolSession {
    session.tools
  }

  private var workspace: WorkspaceLayoutController {
    session.workspace
  }

  @State private var presentedLayout: WorkspaceLayout
  @State private var layoutTransition: WorkspaceLayoutTransition?
  @State private var splitDragOrigin: CGFloat?

  init(workspaces: CaptureWorkspaces, initialWorkspace: WorkspaceLayoutSnapshot? = nil) {
    deviceManager = workspaces.deviceManager
    let session = workspaces.makeSession(initialWorkspace: initialWorkspace)
    _session = State(initialValue: session)
    _presentedLayout = State(initialValue: session.workspace.layout)
    _layoutTransition = State(initialValue: nil)
  }

  var body: some View {
    workspaceContent(controller: controller)
      .onChange(of: workspace.layout, initial: true) {
        session.updatePaneVisibility()
      }
      .focusedSceneValue(\.captureController, controller)
      .background {
        CaptureReviewCloseGuard(
          captureID: controller.review?.operation.id,
          isSaving: controller.review?.isSaving == true
        ) {
          controller.discardCaptureReview()
        }
        .frame(width: 0, height: 0)
      }
      .alert("Capture History", isPresented: Binding(
        get: { history.errorMessage != nil },
        set: { if !$0 { history.update { await $0.clearError() } } }
      )) {
        Button("OK") { history.update { await $0.clearError() } }
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
          shouldFloat: controller.shouldFloatRecordingWindow
        )
        .frame(width: 0, height: 0)
      )
      .background(
        WindowCommandRegistration {
          session.showLivePreview()
        } openDevice: { request in
          session.openDevice(request)
        } attached: { window in
          session.attach(to: window)
        } thumbnail: { connection in
          guard let attachment = controller.livePreviewAttachment(for: connection.deviceID.storedValue),
                attachment.target == connection else { return nil }
          return attachment.thumbnail
        }
        .frame(width: 0, height: 0)
      )
  }

  private var captureDeviceTitle: String? {
    if let request = controller.deviceOpenRequest {
      switch request {
      case .serial(let serial, _, _):
        return deviceTitle(for: serial)
      case .device(let id):
        return deviceTitle(for: id.storedValue)
      case .avd(let name, _):
        return deviceManager.emulators.first { $0.avdName == name }?.title ?? name
      }
    }
    if controller.isLivePreviewActive, let serial = controller.loadingPreviewDeviceID {
      return deviceTitle(for: serial)
    }
    return controller.currentCaptureDeviceTitle
  }

  private func deviceTitle(for serial: String) -> String {
    deviceManager.entries.first { $0.serial == serial }?.title
      ?? deviceManager.connectedDevices.first { $0.id == serial }?.displayTitle
      ?? serial
  }

  private func capturePaneTitle(for layout: WorkspaceLayout) -> CapturePaneTitle? {
    guard layout.showsCapture else { return nil }
    return CapturePaneTitle(title: captureDeviceTitle ?? "Snap-O") {
      openWindow(id: "device-manager")
    }
  }

  private func navigationTitle(for layout: WorkspaceLayout) -> String {
    switch layout {
    case .capture:
      return captureDeviceTitle ?? controller.navigationTitle
    case .tool, .both:
      guard let model = toolSession.model,
            let toolName = model.selectedToolApp?.tools.first(where: {
              $0.kind == model.preferredPluginID
            })?.name.trimmingCharacters(in: .whitespacesAndNewlines),
            !toolName.isEmpty else { return "Snap-O" }
      return toolName
    }
  }

  private func workspaceContent(controller: CapturePaneSession) -> some View {
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
    controller: CapturePaneSession,
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
              VStack(spacing: 0) {
                if let url = toolModel.developmentURL {
                  ToolDevelopmentServerBar(url: url) { toolModel.useDevelopmentServer(nil) }
                }
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
                    } else if toolModel.presentation != .tool {
                      VStack(spacing: 12) {
                        AppToolPlaceholder(presentation: toolModel.presentation, retry: toolModel.retryDiscovery)
                        if let launch = toolModel.appLaunch {
                          Button(launch.pending ? "Opening" : "Open App") { toolModel.openSelectedApp() }
                            .disabled(launch.pending)
                          if let error = launch.error { Text(error).foregroundStyle(.red) }
                        }
                      }
                      .frame(maxWidth: .infinity, maxHeight: .infinity)
                      .background(Color(nsColor: .textBackgroundColor))
                    } else if let error = toolModel.frontendError {
                      VStack(spacing: 12) {
                        if toolModel.developmentURL != nil {
                          Text("Could not load the development frontend").font(.headline)
                        }
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
                      ProgressView("Loading \(toolName)")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color(nsColor: .textBackgroundColor))
                    }
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
    controller: CapturePaneSession,
    layout: WorkspaceLayout
  ) -> some View {
    Group {
      if let review = controller.review {
        CaptureReviewView(review: review) { controller.returnToLive(from: review) }
      } else {
        CaptureSurfaceView(aspectRatio: layout.showsTool ? controller.displayInfoForSizing?.aspectRatio : nil) {
          captureContent(controller: controller)
        }
      }
    }
    .opacity(showsDeviceOpenOverlay ? 0 : 1)
    .allowsHitTesting(!showsDeviceOpenOverlay)
    .accessibilityHidden(showsDeviceOpenOverlay)
    .overlay {
      deviceOpenOverlay
    }
    .overlay(alignment: .top) {
      if controller.previews.count > 1,
         controller.deviceOpenError != nil || controller.hint.isVisible {
        LiveDevicePreviewStrip(
          previews: controller.previews, selectedDeviceID: controller.selectedPreviewDeviceID,
          attachment: controller.currentPreview.flatMap { controller.livePreviewAttachment(for: $0.device.id) },
          loadSnapshot: controller.livePreviewScreenshot, selectDevice: controller.selectDevice
        )
        .padding(.top, 12)
        .onHover { controller.hint.setHovered($0) }
        .transition(.offset(CGSize(width: 0, height: -15)).combined(with: .opacity))
      }
    }
    .animation(.easeInOut(duration: 0.3), value: controller.hint.isVisible)
    .environment(\.livePreviewLoadingMessage, livePreviewLoadingMessage)
    .environment(\.captureImageCopied, controller.imageCopied)
    .overlay {
      CaptureCopyConfirmation(copyID: controller.imageCopyID)
    }
    .background {
      if let serial = livePreviewSerial, workspace.showsCapture {
        let attachment = controller.livePreviewAttachment(for: serial)
        LivePreviewCommandHandler(attachment: attachment)
          .id(serial)
        DeviceControlsPanel(placement: settings.deviceControlsPlacement) {
          DeviceControlsView(
            serial: serial, placement: settings.deviceControlsPlacement,
            attachment: attachment
          ) { key in
            guard let attachment else { throw CancellationError() }
            try await attachment.sendKey(key)
          } didChangeDisplay: {
            attachment?.restartVideo()
          }
          .environment(settings)
          .id(controller.currentPreview?.id)
        }
      }
    }
    .clipped()
    .background(captureAreaBackground)
  }

  private var showsDeviceOpenOverlay: Bool {
    controller.deviceOpenError != nil || pendingDeviceOpenStatus != nil
  }

  @ViewBuilder private var deviceOpenOverlay: some View {
    if let error = controller.deviceOpenError {
      VStack(spacing: 12) {
        Text("Could not open \(captureDeviceTitle ?? "device")")
        Text(error)
          .font(.callout)
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
        HStack(spacing: 12) {
          Button("Cancel", role: .cancel) { session.openDevice(nil) }
            .keyboardShortcut(.cancelAction)
          Button("Retry") {
            if let request = controller.deviceOpenRequest { session.openDevice(request) }
          }
        }
      }
      .multilineTextAlignment(.center)
      .frame(maxWidth: 420)
      .padding(24)
    } else if let status = pendingDeviceOpenStatus {
      WaitingForDeviceView(
        deviceMessage: status,
        serverState: controller.adbServerState,
        retryADBServer: controller.retryADBServer
      ) {
        session.openDevice(nil)
      }
    }
  }

  private var pendingDeviceOpenStatus: String? {
    if let serial = controller.deviceOpenSerial, controller.isLivePreviewActive,
       controller.currentPreview?.device.id == serial { return nil }
    guard let status = controller.deviceOpenStatus else { return nil }
    return controller.deviceOpenSerial.map(livePreviewLoadingMessage) ?? status
  }

  private func livePreviewLoadingMessage(for serial: String) -> String {
    if let entry = deviceManager.entries.first(where: { $0.serial == serial }),
       case .emulator(let device) = entry,
       let status = deviceManager.startupStatus(for: device) {
      return status
    }
    return "Connecting"
  }

  private var livePreviewSerial: String? {
    guard controller.isLivePreviewActive,
          let serial = controller.currentPreview?.device.id else { return nil }
    return serial
  }

  private var captureAreaBackground: some View {
    CapturePaneBackground()
      .overlay(Color.black.opacity(0.06).allowsHitTesting(false))
  }

  private var captureLetterboxBackground: Color {
    Color.clear
  }

  private var toolSidebarBackground: Color {
    if colorScheme == .dark {
      Color(red: 42.0 / 255.0, green: 42.0 / 255.0, blue: 42.0 / 255.0)
    } else {
      Color(red: 244.0 / 255.0, green: 244.0 / 255.0, blue: 244.0 / 255.0)
    }
  }

  private func idleOverlay(controller: CapturePaneSession) -> some View {
    IdleOverlayView(
      hasDevices: controller.hasDevices,
      isDeviceListInitialized: controller.isDeviceListInitialized,
      isProcessing: controller.isProcessing,
      isRecording: controller.isRecording,
      stopRecording: { controller.stopRecording() },
      lastError: nil
    )
  }

  private func captureContent(controller: CapturePaneSession) -> some View {
    ZStack {
      captureLetterboxBackground

      if controller.currentPreview != nil {
        LivePreviewPresentationView(controller: controller)
      } else if controller.adbServerState != .online {
        WaitingForDeviceView(
          serverState: controller.adbServerState,
          retryADBServer: controller.retryADBServer
        )
      } else if controller.isLivePreviewActive, controller.hasDevices {
        WaitingForDeviceView(
          deviceMessage: controller.loadingPreviewDeviceID.map(livePreviewLoadingMessage) ?? "Connecting"
        )
      } else if controller.isDeviceListInitialized {
        idleOverlay(controller: controller)
      } else {
        WaitingForDeviceView()
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
}
