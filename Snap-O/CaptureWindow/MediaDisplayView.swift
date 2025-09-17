import AppKit
import SwiftUI

struct ImageCaptureView: View {
  let url: URL
  var makeTempDragFile: (MediaSaveKind) -> URL?

  var body: some View {
    if let nsImage = NSImage(contentsOf: url) {
      Image(nsImage: nsImage)
        .resizable()
        .scaledToFill()
        .onDrag { dragItemProvider(kind: .image) }
        .onAppear { markPerfMilestones() }
    } else {
      Color.black
    }
  }

  private func dragItemProvider(kind: MediaSaveKind) -> NSItemProvider {
    if let url = makeTempDragFile(kind) {
      NSItemProvider(object: url as NSURL)
    } else {
      NSItemProvider()
    }
  }
}

struct VideoCaptureView: View {
  let url: URL
  var makeTempDragFile: (MediaSaveKind) -> URL?

  var body: some View {
    ZStack {
      VideoLoopingView(url: url)
      Color.gray.opacity(0.01)
        .padding([.bottom], 40)
    }
    .onDrag { dragItemProvider(kind: .video) }
    .onAppear { markPerfMilestones() }
  }

  private func dragItemProvider(kind: MediaSaveKind) -> NSItemProvider {
    if let url = makeTempDragFile(kind) {
      NSItemProvider(object: url as NSURL)
    } else {
      NSItemProvider()
    }
  }
}

private func markPerfMilestones() {
  Perf.end(.captureRequest, finalLabel: "snapshot rendered")
  Perf.end(.recordingRender, finalLabel: "video rendered")
  Perf.end(.appFirstSnapshot, finalLabel: "first media appeared")
}
