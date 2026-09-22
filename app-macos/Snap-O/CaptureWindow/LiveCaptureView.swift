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
  let fileStore: FileStore
  @State private var lifecycle: LivePreviewLifecycle<LivePreviewRenderer>

  init(host: Host, capture: CaptureMedia, fileStore: FileStore) {
    self.fileStore = fileStore
    _lifecycle = State(initialValue: LivePreviewLifecycle(
      connection: host.livePreviewConnection(for: capture.device.id),
      start: { await host.startLivePreviewStream(for: capture.device.id) },
      stop: { await host.stopLivePreviewStream($0) },
      waitUntilStop: { await $0.session.waitUntilStop() },
      readyAt: { $0.session.readyAt },
      canReconnect: { host.canReconnectLivePreview(for: capture.device.id) }
    ))
  }

  var body: some View {
    ZStack {
      Color(nsColor: .unemphasizedSelectedContentBackgroundColor)
      if let renderer = lifecycle.renderer {
        LivePreviewRendererView(
          renderer: renderer,
          fileStore: fileStore,
          isVisible: lifecycle.isWindowVisible,
          thumbnail: lifecycle.connection?.thumbnail
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
    .background {
      WindowVisibilityReader { lifecycle.updateWindowVisibility($0) }
        .frame(width: 0, height: 0)
    }
    .onAppear { lifecycle.appear() }
    .onChange(of: lifecycle.connection?.restartID) { lifecycle.restart() }
    .onDisappear { lifecycle.disappear() }
  }
}
