import SwiftUI

struct CaptureMediaView<Host: LivePreviewHosting>: View {
  @Environment(CaptureHistory.self)
  private var history
  let fileStore: FileStore
  let livePreviewHost: Host
  let capture: CaptureMedia

  var body: some View {
    GeometryReader { proxy in
      ZStack {
        switch capture.media {
        case .image(let url, _):
          ImageCaptureView(
            url: url,
            exportFilename: FileStore.exportFilename(
              capturedAt: capture.media.capturedAt, kind: .image, name: history.name(for: capture.id)
            )
          ) { makeTempDragFile() }

        case .video(let url, _):
          VideoCaptureView(
            url: url
          ) { makeTempDragFile() }

        case .livePreview:
          LiveCaptureView(host: livePreviewHost, capture: capture, fileStore: fileStore)
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
      let fileURL = try fileStore.makeUniqueDragDestination(
        capturedAt: capture.media.capturedAt,
        kind: kind,
        name: history.name(for: capture.id)
      )
      try FileManager.default.copyItem(at: url, to: fileURL)
      return fileURL
    } catch {
      return nil
    }
  }
}
