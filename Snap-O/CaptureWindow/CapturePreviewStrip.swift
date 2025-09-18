import AppKit
import AVFoundation
import SwiftUI

struct CapturePreviewStrip: View {
  let captures: [CaptureMedia]
  let selectedID: CaptureMedia.ID?
  let onSelect: (CaptureMedia.ID) -> Void

  var body: some View {
    HStack(spacing: 16) {
      ForEach(captures) { capture in
        Button {
          onSelect(capture.id)
        } label: {
          CapturePreviewThumbnail(
            capture: capture,
            isSelected: capture.id == selectedID
          ) { dragItemProvider(for: capture) }
        }
        .buttonStyle(.plain)
      }
    }
    .padding(.horizontal, 24)
    .padding(.vertical, 16)
    .background(.ultraThinMaterial)
    .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
    .shadow(color: Color.black.opacity(0.25), radius: 10, x: 0, y: 6)
    .padding(.horizontal, 24)
    .overlayPreferenceValue(PreviewSelectionBoundsKey.self) { anchor in
      GeometryReader { proxy in
        if let anchor {
          let rect = proxy[anchor]
          RoundedRectangle(cornerRadius: 6, style: .continuous)
            .stroke(Color.accentColor, lineWidth: 3)
            .frame(width: rect.width, height: rect.height)
            .position(x: rect.midX, y: rect.midY)
        }
      }
    }
  }
}

private struct CapturePreviewThumbnail: View {
  let capture: CaptureMedia
  let isSelected: Bool
  var dragItemProvider: () -> NSItemProvider

  private let height: CGFloat = 80

  var body: some View {
    ZStack {
      thumbnail
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.6))
        .clipped()

      overlayContent
    }
    .frame(width: targetWidth, height: height)
    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
    .anchorPreference(key: PreviewSelectionBoundsKey.self, value: .bounds) { isSelected ? $0 : nil }
    .onDrag { dragItemProvider() }
  }

  @ViewBuilder private var thumbnail: some View {
    switch capture.media {
    case .image(let url, _):
      if let image = NSImage(contentsOf: url) {
        Image(nsImage: image)
          .resizable()
          .scaledToFill()
      } else {
        Color.gray
      }

    case .video(let url, _):
      VideoPreviewThumbnail(url: url)

    case .livePreview:
      Color.black
    }
  }

  private var overlayContent: some View {
    switch capture.media {
    case .video:
      AnyView(
        Image(systemName: "play.fill")
          .foregroundColor(.white)
          .font(.system(size: 20, weight: .semibold))
          .shadow(radius: 4)
      )
    default:
      AnyView(EmptyView())
    }
  }

  private var targetWidth: CGFloat {
    let aspect = max(CGFloat(capture.media.aspectRatio), 0.1)
    let rawWidth = height * aspect
    let minWidth = height * 0.6
    let maxWidth = height * 2.5
    return min(max(rawWidth, minWidth), maxWidth)
  }
}

private extension CapturePreviewStrip {
  func makeTempDragFile(for capture: CaptureMedia) -> URL? {
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

  func dragItemProvider(for capture: CaptureMedia) -> NSItemProvider {
    if let url = makeTempDragFile(for: capture) {
      return NSItemProvider(object: url as NSURL)
    }
    return NSItemProvider()
  }
}

private struct PreviewSelectionBoundsKey: PreferenceKey {
  static let defaultValue: Anchor<CGRect>? = nil

  static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
    if let next = nextValue() {
      value = next
    }
  }
}

private struct VideoPreviewThumbnail: View {
  let url: URL

  @State private var thumbnail: NSImage?
  @State private var isLoading = false

  var body: some View {
    ZStack {
      if let thumbnail {
        Image(nsImage: thumbnail)
          .resizable()
          .scaledToFill()
      } else {
        Color.gray.opacity(0.6)
        if isLoading {
          ProgressView()
            .progressViewStyle(.circular)
        }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .task(id: url) { await generateThumbnailIfNeeded() }
  }

  private func generateThumbnailIfNeeded() async {
    if let cached = VideoThumbnailCache.shared.image(for: url) {
      thumbnail = cached
      isLoading = false
      return
    }

    isLoading = true

    let asset = AVURLAsset(url: url)
    let generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true
    generator.maximumSize = CGSize(width: 600, height: 600)

    let duration = try? await asset.load(.duration)
    let targetTime = CMTime(
      seconds: 0,
      preferredTimescale: duration?.timescale == 0 ? 600 : duration?.timescale ?? 600
    )

    generator.generateCGImageAsynchronously(for: targetTime) { cgImage, _, _ in
      Task { @MainActor in
        defer {
          isLoading = false
        }

        guard let cgImage else { return }
        let image = NSImage(cgImage: cgImage, size: .zero)
        VideoThumbnailCache.shared.store(image, for: url)
        thumbnail = image
      }
    }
  }
}

final class VideoThumbnailCache {
  nonisolated(unsafe) static let shared = VideoThumbnailCache()

  private var cache: [URL: NSImage] = [:]

  func image(for url: URL) -> NSImage? {
    cache[url]
  }

  func store(_ image: NSImage, for url: URL) {
    cache[url] = image
  }
}
