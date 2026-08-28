import AppKit
import Foundation
import SwiftUI

@MainActor
protocol LivePreviewHosting: AnyObject {
  func startLivePreviewStream(for deviceID: String) async -> LivePreviewRenderer?
  func stopLivePreviewStream(_ renderer: LivePreviewRenderer) async
}

struct LiveCaptureView<Host: LivePreviewHosting>: View {
  let host: Host
  let capture: CaptureMedia
  let fileStore: FileStore

  @State private var renderer: LivePreviewRenderer?
  @State private var streamTask: Task<Void, Never>?
  @State private var cleanupTask: Task<Void, Never>?
  @State private var streamLifecycleID: UUID?
  @State private var connectionError: String?
  @State private var isViewVisible = false
  @State private var isWindowVisible = false

  var body: some View {
    ZStack {
      Color(nsColor: .unemphasizedSelectedContentBackgroundColor)
      if let renderer {
        LivePreviewRendererView(renderer: renderer, fileStore: fileStore, isVisible: isWindowVisible)
      } else if let connectionError {
        VStack(spacing: 8) {
          Text(connectionError)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
          Button("Connect", action: connect)
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
    guard isViewVisible, isWindowVisible, streamTask == nil, connectionError == nil else { return }

    let deviceID = capture.device.id
    let lifecycleID = UUID()
    let previousCleanup = cleanupTask
    streamLifecycleID = lifecycleID
    streamTask = Task(priority: .userInitiated) { @MainActor in
      await previousCleanup?.value
      guard isLifecycleActive(lifecycleID) else { return }
      cleanupTask = nil
      await runRendererLifecycle(deviceID: deviceID, lifecycleID: lifecycleID)
    }
  }

  private func connect() {
    guard streamTask == nil else { return }
    connectionError = nil
    startStreamIfNeeded()
  }

  private func stopStream() {
    streamLifecycleID = nil
    let taskToStop = streamTask
    taskToStop?.cancel()
    streamTask = nil
    let rendererToStop = renderer
    renderer = nil
    guard taskToStop != nil || rendererToStop != nil else { return }

    let previousCleanup = cleanupTask
    cleanupTask = Task {
      await previousCleanup?.value
      if let rendererToStop {
        await host.stopLivePreviewStream(rendererToStop)
      }
      // Startup or a spontaneous stop may still own the device after the renderer is cleared.
      await taskToStop?.value
    }
  }

  @MainActor
  private func runRendererLifecycle(deviceID: String, lifecycleID: UUID) async {
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
      connectionError = "Live preview unavailable"
      return
    }

    renderer = newRenderer
    let stopError = await newRenderer.session.waitUntilStop()
    guard isLifecycleActive(lifecycleID),
          renderer?.operation.id == newRenderer.operation.id else { return }

    renderer = nil
    await host.stopLivePreviewStream(newRenderer)
    guard isLifecycleActive(lifecycleID) else { return }
    if let stopError {
      SnapOLog.ui.error(
        "Live preview stopped: \(stopError.localizedDescription, privacy: .public)"
      )
    }
    connectionError = "Live preview unavailable"
  }

  @MainActor
  private func isLifecycleActive(_ lifecycleID: UUID) -> Bool {
    !Task.isCancelled && streamLifecycleID == lifecycleID
  }
}
