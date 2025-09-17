import SwiftUI

struct LiveCaptureView: View {
  @ObservedObject var controller: CaptureWindowController
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
      let newRenderer = await controller.startLivePreviewStream(for: deviceID)
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
      await controller.stopLivePreviewStream(renderer)
    }
  }

  private func stopCurrentTask() {
    streamTask?.cancel()
    streamTask = nil
  }
}
