import SwiftUI

struct MediaDisplayView: View {
  let media: Media
  let captureVM: CaptureViewModel

  var body: some View {
    Group {
      switch media {
      case let .image(url, _):
        if let nsImage = NSImage(contentsOf: url) {
          Image(nsImage: nsImage)
            .resizable()
            .scaledToFit()
            .onDrag { dragItemProvider(kind: .image) }
        } else {
          Color.black
        }
      case let .video(url, _):
        ZStack {
          VideoLoopingView(url: url)
          // Keep a small overlay area to make drag easier
          Color.gray.opacity(0.01)
            .padding([.bottom], 40)
        }
        .onDrag { dragItemProvider(kind: .video) }
      case .livePreview:
        LivePreviewView(captureVM: captureVM)
      }
    }
  }

  private func dragItemProvider(kind: MediaSaveKind) -> NSItemProvider {
    if let url = captureVM.makeTempDragFile(kind: kind) {
      NSItemProvider(object: url as NSURL)
    } else {
      NSItemProvider()
    }
  }
}
