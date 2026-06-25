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

  @State private var renderer: LivePreviewRenderer?
  @State private var streamTask: Task<Void, Never>?
  @State private var streamLifecycleID: UUID?

  var body: some View {
    ZStack {
      if let renderer {
        LivePreviewRendererView(renderer: renderer)
      } else {
        Color.black
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .onAppear { startStreamIfNeeded() }
    .onDisappear { stopStream() }
  }

  private func startStreamIfNeeded() {
    guard streamTask == nil else { return }
    restartStream()
  }

  private func restartStream() {
    stopStream()

    let deviceID = capture.device.id
    let lifecycleID = UUID()
    streamLifecycleID = lifecycleID
    streamTask = Task(priority: .userInitiated) { @MainActor in
      await runRendererLifecycle(deviceID: deviceID, lifecycleID: lifecycleID)
    }
  }

  private func stopStream() {
    streamLifecycleID = nil
    streamTask?.cancel()
    streamTask = nil
    let rendererToStop = renderer
    renderer = nil
    if let rendererToStop {
      Task {
        await host.stopLivePreviewStream(rendererToStop)
      }
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
