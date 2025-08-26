import SwiftUI

struct MediaDisplayView: View {
  let media: Media
  let captureVM: CaptureViewModel

  var body: some View {
    Group {
      switch media.kind {
      case .image:
        if let nsImage = NSImage(contentsOf: media.url) {
          Image(nsImage: nsImage)
            .resizable()
            .scaledToFit()
            .onDrag { dragItemProvider() }
        } else {
          Color.black
        }
      case .video:
        ZStack {
          VideoLoopingView(url: media.url)
          // Keep a small overlay area to make drag easier
          Color.gray.opacity(0.01)
            .padding([.bottom], 40)
        }
        .onDrag { dragItemProvider() }
      }
    }
  }

  private func dragItemProvider() -> NSItemProvider {
    if let url = captureVM.makeTempDragFile() {
      NSItemProvider(object: url as NSURL)
    } else {
      NSItemProvider()
    }
  }
}
