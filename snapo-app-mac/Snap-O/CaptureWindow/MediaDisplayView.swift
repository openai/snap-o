import AppKit
import SwiftUI

struct ImageCaptureView: View {
  let url: URL
  var makeTempDragFile: () -> URL?

  @StateObject private var loader = ImageLoader()

  var body: some View {
    if let nsImage = loader.image(url: url) {
      Image(nsImage: nsImage)
        .resizable()
        .scaledToFill()
        .clipped()
        .onDrag { dragItemProvider() }
        .onAppear { markPerfMilestones() }
    } else {
      Color.black
    }
  }

  private func dragItemProvider() -> NSItemProvider {
    if let url = makeTempDragFile() {
      NSItemProvider(object: url as NSURL)
    } else {
      NSItemProvider()
    }
  }
}

struct VideoCaptureView: View {
  let url: URL
  var makeTempDragFile: () -> URL?

  var body: some View {
    ZStack {
      VideoLoopingView(url: url)
      Color.gray.opacity(0.01)
        .padding([.bottom], 40)
    }
    .clipped()
    .onDrag { dragItemProvider() }
    .onAppear { markPerfMilestones() }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private func dragItemProvider() -> NSItemProvider {
    if let url = makeTempDragFile() {
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

@MainActor
final class ImageLoader: ObservableObject {
  private var image: NSImage?
  private var url: URL?

  func image(url: URL) -> NSImage? {
    guard url != self.url else { return image }
    self.url = url
    let nsImage = NSImage(contentsOf: url)
    image = nsImage
    return nsImage
  }
}
