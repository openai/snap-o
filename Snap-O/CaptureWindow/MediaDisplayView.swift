import AppKit
import SwiftUI

struct MediaDisplayView: View {
  let media: Media
  var makeTempDragFile: (MediaSaveKind) -> URL?
  var livePreviewRenderer: LivePreviewRenderer?

  var body: some View {
    Group {
      switch media {
      case .image(let url, _):
        if let nsImage = NSImage(contentsOf: url) {
          Image(nsImage: nsImage)
            .resizable()
            .scaledToFill()
            .onDrag { dragItemProvider(kind: .image) }
            .onAppear { markPerfMilestones() }
        } else {
          Color.black
        }
      case .video(let url, _):
        ZStack {
          VideoLoopingView(url: url)
          Color.gray.opacity(0.01)
            .padding([.bottom], 40)
        }
        .onDrag { dragItemProvider(kind: .video) }
        .onAppear { markPerfMilestones() }
      case .livePreview:
        if let renderer = livePreviewRenderer {
          LivePreviewView(renderer: renderer)
        } else {
          Color.black
        }
      }
    }
  }

  private func dragItemProvider(kind: MediaSaveKind) -> NSItemProvider {
    if let url = makeTempDragFile(kind) {
      NSItemProvider(object: url as NSURL)
    } else {
      NSItemProvider()
    }
  }

  private func markPerfMilestones() {
    Perf.end(.captureRequest, finalLabel: "snapshot rendered")
    Perf.end(.recordingRender, finalLabel: "video rendered")
    Perf.end(.appFirstSnapshot, finalLabel: "first media appeared")
  }
}
