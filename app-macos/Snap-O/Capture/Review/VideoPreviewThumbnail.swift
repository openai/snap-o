import AppKit
import AVFoundation
import SwiftUI

struct VideoPreviewThumbnail: View {
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
