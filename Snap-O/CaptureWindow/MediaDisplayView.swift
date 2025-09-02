import SwiftUI

struct MediaDisplayView: View {
  let media: Media
  let controller: CaptureController

  var body: some View {
    Group {
      switch media {
      case .image(let url, _):
        if let nsImage = NSImage(contentsOf: url) {
          Image(nsImage: nsImage)
            .resizable()
            .scaledToFit()
            .onDrag { dragItemProvider(kind: .image) }
        } else {
          Color.black
        }
      case .video(let url, _):
        ZStack {
          VideoLoopingView(url: url)
          // Keep a small overlay area to make drag easier
          Color.gray.opacity(0.01)
            .padding([.bottom], 40)
        }
        .onDrag { dragItemProvider(kind: .video) }
      case .livePreview:
        LivePreviewView(controller: controller)
      }
    }
  }

  private func dragItemProvider(kind: MediaSaveKind) -> NSItemProvider {
    if let url = controller.makeTempDragFile(kind: kind) {
      NSItemProvider(object: url as NSURL)
    } else {
      NSItemProvider()
    }
  }
}
