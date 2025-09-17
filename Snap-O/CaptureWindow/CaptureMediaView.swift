import SwiftUI

struct CaptureMediaView: View {
  let controller: CaptureWindowController
  let capture: CaptureMedia

  var body: some View {
    GeometryReader { proxy in
      ZStack {
        switch capture.media {
        case .image(let url, _):
          ImageCaptureView(
            url: url
          ) { makeTempDragFile() }

        case .video(let url, _):
          VideoCaptureView(
            url: url
          ) { makeTempDragFile() }

        case .livePreview:
          LiveCaptureView(controller: controller, capture: capture)
        }
      }
      .frame(width: proxy.size.width, height: proxy.size.height)
      .clipped()
      .id(capture.id)
    }
  }

  private func makeTempDragFile() -> URL? {
    guard let kind = capture.media.saveKind, let url = capture.media.url else { return nil }

    do {
      let fileStore = AppServices.shared.fileStore
      let fileURL = fileStore.makeDragDestination(
        capturedAt: capture.media.capturedAt,
        kind: kind
      )
      if !FileManager.default.fileExists(atPath: fileURL.path) {
        try FileManager.default.copyItem(at: url, to: fileURL)
      }
      return fileURL
    } catch {
      return nil
    }
  }
}
