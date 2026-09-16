import AppKit
@preconcurrency import AVFoundation
import ImageIO
import SwiftUI

@MainActor
private final class HistoryThumbnailCache {
  static let shared = HistoryThumbnailCache()
  private let images = NSCache<NSURL, NSImage>()

  private init() {
    images.totalCostLimit = 32 * 1024 * 1024
  }

  func image(url: URL, kind: CaptureHistoryEntry.Kind) async -> NSImage? {
    if let image = images.object(forKey: url as NSURL) { return image }
    let bitmap = await Task.detached(priority: .utility) {
      if kind == .image {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil as CGImage? }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
          kCGImageSourceCreateThumbnailFromImageAlways: true,
          kCGImageSourceCreateThumbnailWithTransform: true,
          kCGImageSourceThumbnailMaxPixelSize: 640
        ] as CFDictionary)
      }
      let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
      generator.appliesPreferredTrackTransform = true
      generator.maximumSize = CGSize(width: 640, height: 640)
      return try? await generator.image(at: .zero).image
    }.value
    guard let bitmap else { return nil }
    let image = NSImage(cgImage: bitmap, size: .zero)
    images.setObject(image, forKey: url as NSURL, cost: bitmap.bytesPerRow * bitmap.height)
    return image
  }
}

struct CaptureHistoryThumbnail: View {
  let entry: CaptureHistoryEntry
  let item: CaptureHistoryEntry.Item
  let root: URL
  @State private var image: NSImage?
  @State private var finishedLoading = false

  var body: some View {
    Group {
      if let image {
        Image(nsImage: image)
          .resizable()
          .scaledToFit()
          .clipShape(RoundedRectangle(cornerRadius: 4))
          .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
      } else if finishedLoading || !item.isAvailable {
        Image(systemName: item.failure == nil ? "photo" : "exclamationmark.triangle")
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        ProgressView().controlSize(.small)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .task(id: item.captureID) {
      guard item.isAvailable else { return }
      image = await HistoryThumbnailCache.shared.image(url: entry.fileURL(for: item, in: root), kind: entry.kind)
      finishedLoading = true
    }
    .accessibilityHidden(true)
  }
}

struct CaptureHistoryStack: View {
  let entry: CaptureHistoryEntry
  let root: URL
  let refreshedAt: Date

  private var items: [CaptureHistoryEntry.Item] {
    Array(entry.availableItems.prefix(3))
  }

  var body: some View {
    VStack(spacing: 12) {
      ZStack {
        if items.isEmpty {
          Image(systemName: entry.completedAt == nil ? entry.kind.symbol : "exclamationmark.triangle")
            .foregroundStyle(.secondary)
        }
        ForEach(Array(items.enumerated().reversed()), id: \.element.id) { index, item in
          CaptureHistoryThumbnail(entry: entry, item: item, root: root)
            .frame(width: min(154, 144 * item.aspectRatio), height: 144)
            .offset(x: CGFloat(index) * 9, y: CGFloat(index) * -6)
        }
      }
      .frame(width: 190, height: 176)

      TimelineView(.periodic(from: .now, by: 60)) { context in
        HStack(spacing: 6) {
          Image(systemName: entry.kind.symbol)
          Text(Self.relativeTime(entry.capturedAt, now: max(context.date, refreshedAt)))
          if entry.hasFailures { Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange) }
          if entry.completedAt == nil { ProgressView().controlSize(.mini) }
        }
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
      }
    }
    .help([entry.frontItem?.deviceName, entry.capturedAt.formatted(date: .abbreviated, time: .shortened)]
      .compactMap(\.self).joined(separator: " · "))
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("\(entry.kind.title), \(entry.capturedAt.formatted()), \(entry.frontItem?.deviceName ?? "Unavailable")")
    .accessibilityValue(entry.hasFailures ? "Some devices failed to capture" : "")
  }

  static func relativeTime(_ date: Date, now: Date) -> String {
    let seconds = max(0, Int(now.timeIntervalSince(date)))
    if seconds < 60 { return "Just now" }
    if seconds < 3600 { return "\(seconds / 60)m ago" }
    if seconds < 86400 { return "\(seconds / 3600)h ago" }
    return "\(seconds / 86400)d ago"
  }
}
