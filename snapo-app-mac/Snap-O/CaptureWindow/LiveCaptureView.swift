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
  @State private var isViewVisible = false
  @State private var isWindowVisible = false

  var body: some View {
    ZStack {
      if let renderer {
        LivePreviewRendererView(renderer: renderer, fileStore: fileStore)
      } else {
        Color(nsColor: .unemphasizedSelectedContentBackgroundColor)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background {
      WindowVisibilityReader { isVisible in
        isWindowVisible = isVisible
        updateStreamVisibility()
      }
      .frame(width: 0, height: 0)
    }
    .onAppear {
      isViewVisible = true
      updateStreamVisibility()
    }
    .onDisappear {
      isViewVisible = false
      stopStream()
    }
  }

  private func updateStreamVisibility() {
    if isViewVisible, isWindowVisible {
      startStreamIfNeeded()
    } else {
      stopStream()
    }
  }

  private func startStreamIfNeeded() {
    guard streamTask == nil else { return }

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
    var retryAttempt = 0

    while isLifecycleActive(lifecycleID) {
      let newRenderer = await host.startLivePreviewStream(for: deviceID)
      guard isLifecycleActive(lifecycleID) else {
        if let newRenderer {
          await host.stopLivePreviewStream(newRenderer)
        }
        return
      }

      guard let newRenderer else {
        guard await waitBeforeRetry(attempt: retryAttempt, lifecycleID: lifecycleID) else { return }
        retryAttempt += 1
        continue
      }

      renderer = newRenderer
      let stopError = await newRenderer.session.waitUntilStop()
      guard streamLifecycleID == lifecycleID,
            renderer?.operation.id == newRenderer.operation.id else { return }

      renderer = nil
      await host.stopLivePreviewStream(newRenderer)
      if let stopError {
        SnapOLog.ui.error(
          "Live preview stopped: \(stopError.localizedDescription, privacy: .public)"
        )
      }

      guard await waitBeforeRetry(attempt: retryAttempt, lifecycleID: lifecycleID) else { return }
      retryAttempt += 1
    }

    if streamLifecycleID == lifecycleID {
      streamLifecycleID = nil
      streamTask = nil
    }
  }

  @MainActor
  private func waitBeforeRetry(attempt: Int, lifecycleID: UUID) async -> Bool {
    let exponent = min(attempt, 4)
    let delayMilliseconds = min(200 * (1 << exponent), 2000)
    do {
      try await Task.sleep(for: .milliseconds(delayMilliseconds))
    } catch {
      return false
    }
    return isLifecycleActive(lifecycleID)
  }

  @MainActor
  private func isLifecycleActive(_ lifecycleID: UUID) -> Bool {
    !Task.isCancelled && streamLifecycleID == lifecycleID
  }
}
