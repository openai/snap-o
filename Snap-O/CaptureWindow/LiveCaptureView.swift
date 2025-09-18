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
    guard renderer == nil else { return }
    restartStream()
  }

  private func restartStream() {
    stopCurrentTask()

    let deviceID = capture.device.id
    streamTask = Task(priority: .userInitiated) {
      let newRenderer = await host.startLivePreviewStream(for: deviceID)
      await MainActor.run {
        renderer = newRenderer
        streamTask = nil
      }
    }
  }

  private func stopStream() {
    stopCurrentTask()

    guard let renderer else { return }
    self.renderer = nil
    Task {
      await host.stopLivePreviewStream(renderer)
    }
  }

  private func stopCurrentTask() {
    streamTask?.cancel()
    streamTask = nil
  }
}
