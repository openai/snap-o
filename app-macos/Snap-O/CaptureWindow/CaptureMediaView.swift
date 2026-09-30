import SwiftUI

struct CaptureMediaView<Host: LivePreviewHosting>: View {
  @Environment(CaptureHistory.self)
  private var history
  let fileStore: FileStore
  let livePreviewHost: Host
  let capture: CaptureMedia
  var allowsFileDrag = true
  var crop = CaptureCropGeometry.fullImage

  var body: some View {
    GeometryReader { proxy in
      ZStack {
        switch capture.media {
        case .image(let url, _):
          ImageCaptureView(
            url: url,
            exportFilename: FileStore.exportFilename(
              capturedAt: capture.media.capturedAt, kind: .image, name: history.name(for: capture.id)
            ),
            allowsFileDrag: allowsFileDrag,
            crop: crop
          ) { makeTempDragFile() }

        case .video(let url, _):
          VideoCaptureView(
            url: url,
            allowsFileDrag: allowsFileDrag
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
      return try fileStore.makeDragCopy(
        of: url,
        capturedAt: capture.media.capturedAt,
        kind: kind,
        name: history.name(for: capture.id)
      )
    } catch {
      return nil
    }
  }
}
