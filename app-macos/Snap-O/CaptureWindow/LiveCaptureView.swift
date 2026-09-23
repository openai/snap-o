import AppKit
import Foundation
import SwiftUI

@MainActor
protocol LivePreviewHosting: AnyObject {
  func livePreviewConnection(for deviceID: String) -> LivePreviewConnection?
  func canReconnectLivePreview(for deviceID: String) -> Bool
  func startLivePreviewStream(for deviceID: String) async -> LivePreviewRenderer?
  func stopLivePreviewStream(_ renderer: LivePreviewRenderer) async
  func livePreviewScreenshot(for deviceID: String) async throws -> Data
}

struct LiveCaptureView<Host: LivePreviewHosting>: View {
  @Environment(AppSettings.self)
  private var settings
  @Environment(\.appearsActive)
  private var appearsActive
  @Environment(\.scenePhase)
  private var scenePhase
  let fileStore: FileStore
  private let deviceID: String
  @State private var lifecycle: LivePreviewLifecycle<LivePreviewRenderer>
  @State private var fileDrop: DeviceFileDrop
  @State private var clipboardFocus = ClipboardSyncFocus()
  @State private var keyboard: LivePreviewKeyboard

  init(host: Host, capture: CaptureMedia, fileStore: FileStore) {
    self.fileStore = fileStore
    _fileDrop = State(initialValue: DeviceFileDrop(device: capture.device))
    deviceID = capture.device.id
    _keyboard = State(initialValue: LivePreviewKeyboard(deviceID: capture.device.id))
    _lifecycle = State(initialValue: LivePreviewLifecycle(
      connection: host.livePreviewConnection(for: capture.device.id),
      start: { await host.startLivePreviewStream(for: capture.device.id) },
      stop: { await host.stopLivePreviewStream($0) },
      waitUntilStop: { await $0.session.waitUntilStop() },
      readyAt: { $0.session.readyAt },
      canReconnect: { host.canReconnectLivePreview(for: capture.device.id) }
    ))
  }

  private var clipboardTarget: String? {
    settings.syncClipboard
      && clipboardFocus.isActive && lifecycle.renderer != nil && lifecycle.isWindowVisible ? deviceID : nil
  }

  var body: some View {
    ZStack {
      Color(nsColor: .unemphasizedSelectedContentBackgroundColor)
      if let renderer = lifecycle.renderer {
        LivePreviewRendererView(
          renderer: renderer,
          fileStore: fileStore,
          isVisible: lifecycle.isWindowVisible,
          thumbnail: lifecycle.connection?.thumbnail,
          keyboard: settings.keyboardInput ? keyboard : nil
        )
      } else if lifecycle.connection?.hasFailed == true {
        VStack(spacing: 8) {
          Text("Live preview unavailable")
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
          Button("Connect", action: lifecycle.connect)
            .disabled(lifecycle.isConnecting)
        }
        .padding(16)
      } else if lifecycle.isConnecting {
        WaitingForDeviceView(isDeviceListInitialized: true, deviceMessage: "Connecting to device")
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .dropDestination(for: URL.self, isEnabled: fileDrop.canAcceptDrop) { urls, _ in
      fileDrop.receive(urls)
    }
    .dropConfiguration { _ in DropConfiguration(operation: .copy) }
    .overlay(alignment: .bottom) {
      VStack(spacing: 0) {
        if fileDrop.isBusy || fileDrop.status != nil || !fileDrop.failures.isEmpty {
          DeviceFileDropStatus(model: fileDrop)
        }
        if let message = keyboard.errorMessage {
          HStack(spacing: 8) {
            Text(message)
              .frame(maxWidth: .infinity, alignment: .leading)
            Button { keyboard.errorMessage = nil } label: {
              Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss keyboard status")
          }
          .font(.callout)
          .padding(10)
          .background(Color(nsColor: .windowBackgroundColor).opacity(0.95))
        }
      }
    }
    .alert(fileDrop.installPrompt, isPresented: $fileDrop.asksToInstall) {
      Button("Install") { fileDrop.start(install: true) }
      Button("Copy to Downloads") { fileDrop.start(install: false) }
      Button("Cancel", role: .cancel) { fileDrop.pendingFiles = [] }
    } message: {
      if !fileDrop.installMessage.isEmpty { Text(fileDrop.installMessage) }
    }
    .alert(
      "“\(fileDrop.conflictName)” already exists",
      isPresented: $fileDrop.asksAboutConflict
    ) {
      Button("Keep Both") { fileDrop.answerConflict(.keepBoth) }
      Button("Replace", role: .destructive) { fileDrop.answerConflict(.replace) }
      Button("Skip", role: .cancel) { fileDrop.answerConflict(.skip) }
    }
    .background {
      WindowVisibilityReader { visible in
        if !visible { clipboardFocus.stop() }
        lifecycle.updateWindowVisibility(visible)
      }
      .frame(width: 0, height: 0)
    }
    .onChange(of: appearsActive && scenePhase == .active, initial: true) {
      clipboardFocus.update(focused: appearsActive, appActive: scenePhase == .active)
    }
    .onAppear { lifecycle.appear() }
    .onChange(of: lifecycle.connection?.restartID) { lifecycle.restart() }
    .onDisappear {
      keyboard.stop()
      clipboardFocus.sync?.stop()
      lifecycle.disappear()
      fileDrop.cancel()
    }
    .task(id: clipboardTarget.map { "\($0):\(clipboardFocus.revision)" }) {
      guard !Task.isCancelled else { return }
      clipboardFocus.sync?.stop()
      clipboardFocus.sync = nil
      lifecycle.connection?.clipboard = nil
      guard let serial = clipboardTarget else { return }
      let sync = ClipboardSync(settings: settings)
      clipboardFocus.sync = sync
      lifecycle.connection?.clipboard = sync
      defer { sync.stop() }
      await sync.run(serial: serial)
    }
  }
}
