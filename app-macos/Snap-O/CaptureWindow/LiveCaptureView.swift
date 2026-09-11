import AppKit
import Foundation
import SwiftUI

@MainActor
protocol LivePreviewHosting: AnyObject {
  func livePreviewConnection(for deviceID: String) -> LivePreviewConnection?
  func startLivePreviewStream(for deviceID: String) async -> LivePreviewRenderer?
  func stopLivePreviewStream(_ renderer: LivePreviewRenderer) async
}

struct LiveCaptureView<Host: LivePreviewHosting>: View {
  let host: Host
  let capture: CaptureMedia
  let fileStore: FileStore
  private let connection: LivePreviewConnection?

  @State private var renderer: LivePreviewRenderer?
  @State private var streamTask: Task<Void, Never>?
  @State private var streamLifecycleID: UUID?
  @State private var isViewVisible = false
  @State private var isWindowVisible = false

  init(host: Host, capture: CaptureMedia, fileStore: FileStore) {
    self.host = host
    self.capture = capture
    self.fileStore = fileStore
    connection = host.livePreviewConnection(for: capture.device.id)
  }

  var body: some View {
    ZStack {
      Color(nsColor: .unemphasizedSelectedContentBackgroundColor)
      if let renderer {
        LivePreviewRendererView(renderer: renderer, fileStore: fileStore, isVisible: isWindowVisible)
      } else if connection?.hasFailed == true {
        VStack(spacing: 8) {
          Text("Live preview unavailable")
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
          Button("Connect", action: connect)
            .disabled(streamTask != nil)
        }
        .padding(16)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background {
      WindowVisibilityReader { isVisible in
        isWindowVisible = isVisible
        startStreamIfNeeded()
      }
      .frame(width: 0, height: 0)
    }
    .onAppear {
      isViewVisible = true
      startStreamIfNeeded()
    }
    .onDisappear {
      isViewVisible = false
      stopStream()
    }
  }

  private func startStreamIfNeeded() {
    guard isViewVisible, isWindowVisible, streamTask == nil,
          let connection, !connection.hasFailed else { return }

    let deviceID = capture.device.id
    let lifecycleID = UUID()
    let previousCleanup = connection.cleanupTask
    streamLifecycleID = lifecycleID
    streamTask = Task(priority: .userInitiated) { @MainActor in
      await previousCleanup?.value
      guard isLifecycleActive(lifecycleID) else { return }
      connection.cleanupTask = nil
      await runRendererLifecycle(deviceID: deviceID, lifecycleID: lifecycleID, connection: connection)
    }
  }

  private func connect() {
    guard streamTask == nil, let connection else { return }
    connection.hasFailed = false
    startStreamIfNeeded()
  }

  private func stopStream() {
    streamLifecycleID = nil
    let taskToStop = streamTask
    taskToStop?.cancel()
    streamTask = nil
    let rendererToStop = renderer
    renderer = nil
    guard let connection, taskToStop != nil || rendererToStop != nil else { return }

    let previousCleanup = connection.cleanupTask
    connection.cleanupTask = Task {
      await previousCleanup?.value
      if let rendererToStop {
        await host.stopLivePreviewStream(rendererToStop)
      }
      // Startup or a spontaneous stop may still own the device after the renderer is cleared.
      await taskToStop?.value
    }
  }

  @MainActor
  private func runRendererLifecycle(deviceID: String, lifecycleID: UUID, connection: LivePreviewConnection) async {
    defer {
      if streamLifecycleID == lifecycleID {
        streamLifecycleID = nil
        streamTask = nil
      }
    }
    let newRenderer = await host.startLivePreviewStream(for: deviceID)
    guard isLifecycleActive(lifecycleID) else {
      if let newRenderer {
        await host.stopLivePreviewStream(newRenderer)
      }
      return
    }

    guard let newRenderer else {
      connection.hasFailed = true
      return
    }

    renderer = newRenderer
    let stopError = await newRenderer.session.waitUntilStop()
    guard isLifecycleActive(lifecycleID),
          renderer?.operation.id == newRenderer.operation.id else { return }

    connection.hasFailed = true
    renderer = nil
    // Retain cleanup across selection changes before exposing a manual retry.
    let cleanup = Task { await host.stopLivePreviewStream(newRenderer) }
    connection.cleanupTask = cleanup
    await cleanup.value
    guard isLifecycleActive(lifecycleID) else { return }
    if let stopError {
      SnapOLog.ui.error(
        "Live preview stopped: \(stopError.localizedDescription, privacy: .public)"
      )
    }
  }

  @MainActor
  private func isLifecycleActive(_ lifecycleID: UUID) -> Bool {
    !Task.isCancelled && streamLifecycleID == lifecycleID
  }
}
