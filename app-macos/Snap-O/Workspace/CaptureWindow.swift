import AppKit
import Observation
import SwiftUI

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
        } fullScreenChanged: { event in
          switch event {
          case .willChange:
            controller.displayedPreview?.beginFullScreenChange()
          case .didChange(let windowIsVisible):
            controller.displayedPreview?.finishFullScreenChange(windowIsVisible: windowIsVisible)
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

  private var captureDeviceLabel: (name: String, server: String?)? {
    if let request = controller.deviceOpenRequest {
      switch request {
      case .serial(let serial, let server, let serverID):
        if let serverID {
          return deviceLabel(for: DeviceID(serverID: serverID, serial: serial).storedValue)
        }
        let matches = deviceManager.linkServers().filter { $0.value.isEnabled && server.matches($0.value.server) }
        if matches.count == 1, let match = matches.first {
          return deviceLabel(for: DeviceID(serverID: match.key, serial: serial).storedValue)
        }
        switch server {
        case .local:
          return deviceLabel(for: serial)
        case .ssh(let destination, let port, let adbPort):
          let address = SSHConfiguration(destination: destination, port: port, adbPort: adbPort).displayAddress
          return (serial, address)
        }
      case .device(let id):
        return deviceLabel(for: id.storedValue)
      case .avd(let name, _):
        return (deviceManager.emulators.first { $0.avdName == name }?.title ?? name, nil)
      }
    }
    if controller.isLivePreviewActive, let serial = controller.loadingPreviewDeviceID {
      return deviceLabel(for: serial)
    }
    guard let title = controller.currentCaptureDeviceTitle else { return nil }
    return labelWithServer(title, deviceID: controller.selectedDeviceID)
  }

  private func deviceLabel(for storedID: String) -> (name: String, server: String?) {
    let title = deviceManager.entries.first { $0.serial == storedID }?.title
      ?? deviceManager.connectedDevices.first { $0.id == storedID }?.displayTitle
      ?? DeviceID(storedValue: storedID).serial
    return labelWithServer(title, deviceID: storedID)
  }

  private func labelWithServer(_ title: String, deviceID: String?) -> (name: String, server: String?) {
    let server = deviceID.flatMap { deviceManager.remoteServerLabel(for: DeviceID(storedValue: $0)) }
    return (title, server)
  }

  private var captureDeviceTitle: String? {
    guard let label = captureDeviceLabel else { return nil }
    return [label.name, label.server].compactMap(\.self).joined(separator: " ")
  }

  private func capturePaneTitle(for layout: WorkspaceLayout) -> CapturePaneTitle? {
    guard layout.showsCapture else { return nil }
    let label = captureDeviceLabel
    return CapturePaneTitle(title: label?.name ?? "Snap-O", serverName: label?.server) {
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
      let aspectRatio = controller.displayInfoForSizing?.aspectRatio
      let presentation = WorkspacePanePresentation(
        layout: presentedLayout, windowWidth: geometry.size.width, preferredCaptureWidth: workspace.capturePaneWidth,
        captureAspectRatio: aspectRatio, transition: layoutTransition
      )

      VStack(spacing: 0) {
        CaptureToolbar(
          controller: controller,
          workspace: workspace,
          presentation: presentation,
          toolModel: toolSession.model,
          titlebarHeight: titlebarHeight
        )

        captureWorkspace(
          controller: controller,
          presentation: presentation
        )
      }
      .background(toolSidebarBackground, ignoresSafeAreaEdges: [])
      .overlayPreferenceValue(CaptureWorkspaceMetricsKey.self) { metrics in
        if presentation.layout == .both,
           presentation.transitioningPane == nil,
           let metrics {
          workspaceSplitter(
            totalWidth: geometry.size.width,
            previewHeight: metrics.previewHeight,
            aspectRatio: aspectRatio
          )
          .frame(width: 1, height: metrics.previewHeight)
          .offset(x: presentation.captureWidth - 0.5)
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        }
      }
      .background(
        WindowChromeController(
          title: navigationTitle(for: presentation.layout),
          dividerX: presentation.dividerX,
          captureTitle: capturePaneTitle(for: presentation.layout)
        )
        .frame(width: 0, height: 0)
      )
      .ignoresSafeArea(.container, edges: .top)
    }
  }

  private func captureWorkspace(
    controller: CapturePaneSession,
    presentation: WorkspacePanePresentation
  ) -> some View {
    GeometryReader { geometry in
      let previewHeight = geometry.size.height

      ZStack(alignment: .topLeading) {
        if presentation.layout.showsCapture {
          capturePane(controller: controller)
            .frame(width: presentation.captureWidth, height: previewHeight)
            .frame(
              width: presentation.captureVisibleWidth,
              height: previewHeight,
              alignment: .leading
            )
            .clipped()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .zIndex(presentation.zIndex(for: .capture))
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
          .zIndex(presentation.zIndex(for: .tool))
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

  private func capturePane(controller: CapturePaneSession) -> some View {
    Group {
      if let review = controller.review {
        CaptureReviewView(review: review) { controller.returnToLive(from: review) }
      } else {
        CaptureSurfaceView(aspectRatio: controller.displayInfoForSizing?.aspectRatio) {
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
          loadSnapshot: controller.livePreviewScreenshot,
          serverName: { deviceManager.remoteServerLabel(for: $0.identity) },
          selectDevice: controller.selectDevice
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
            placement: settings.deviceControlsPlacement,
            attachment: attachment
          ) {
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
      Color.clear

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
              to: WorkspaceLayout.constrainedCapturePaneWidth(
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
              to: WorkspaceLayout.constrainedCapturePaneWidth(
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
}
