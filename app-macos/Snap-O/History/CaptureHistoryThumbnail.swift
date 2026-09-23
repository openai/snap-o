import AppKit
@preconcurrency import AVFoundation
import ImageIO
import SwiftUI

@MainActor
private final class HistoryThumbnailCache {
  static let shared = HistoryThumbnailCache()
  private let images = NSCache<NSURL, NSImage>()
  private var pending: Task<CGImage?, Never>?

  private init() {
    images.totalCostLimit = 32 * 1024 * 1024
  }

  func image(url: URL, kind: CaptureHistoryEntry.Kind) async -> NSImage? {
    guard !Task.isCancelled else { return nil }
    if let image = images.object(forKey: url as NSURL) { return image }
    let previous = pending
    // Decode one thumbnail at a time; canceled requests skip their turn.
    let task = Task.detached(priority: .utility) {
      _ = await previous?.value
      guard !Task.isCancelled else { return nil as CGImage? }
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
      return await withTaskCancellationHandler {
        try? await generator.image(at: .zero).image
      } onCancel: {
        generator.cancelAllCGImageGeneration()
      }
    }
    pending = task
    let bitmap = await withTaskCancellationHandler {
      await task.value
    } onCancel: {
      task.cancel()
    }
    if pending == task { pending = nil }
    guard !Task.isCancelled, let bitmap else { return nil }
    let image = NSImage(cgImage: bitmap, size: .zero)
    images.setObject(image, forKey: url as NSURL, cost: bitmap.bytesPerRow * bitmap.height)
    return image
  }
}

struct CaptureHistoryThumbnail: View {
  let entry: CaptureHistoryEntry
  let item: CaptureHistoryEntry.Item
  let root: URL
  var showsPlaybackIndicator = true
  var squareSize: CGFloat?
  @State private var image: NSImage?
  @State private var finishedLoading = false

  var body: some View {
    Group {
      if let image {
        Image(nsImage: image)
          .resizable()
          .aspectRatio(contentMode: squareSize == nil ? .fit : .fill)
          .frame(width: squareSize, height: squareSize)
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
    .overlay {
      if entry.kind == .video, item.isAvailable, showsPlaybackIndicator {
        let isCompact = squareSize != nil
        Image(systemName: "play.fill")
          .font(.system(size: isCompact ? 7 : 14, weight: .semibold))
          .foregroundStyle(.white)
          .frame(width: isCompact ? 16 : 32, height: isCompact ? 16 : 32)
          .background(.black.opacity(0.55), in: Circle())
          .allowsHitTesting(false)
          .accessibilityHidden(true)
      }
    }
    .task(id: item.captureID) {
      finishedLoading = false
      guard item.isAvailable else { return }
      let thumbnail = await HistoryThumbnailCache.shared.image(url: entry.fileURL(for: item, in: root), kind: entry.kind)
      guard !Task.isCancelled else { return }
      image = thumbnail
      finishedLoading = true
    }
    .onDisappear { image = nil }
    .accessibilityHidden(true)
  }
}

struct CaptureHistoryStack: View {
  let entry: CaptureHistoryEntry
  let root: URL
  let refreshedAt: Date
  @Binding var draggedMedia: CaptureHistoryDraggedMedia?
  let exportFile: (CaptureHistoryEntry.Item) -> URL?
  let isSelected: Bool
  let canDelete: Bool
  let select: () -> Void
  let open: () -> Void
  let rename: (String) -> Void
  let delete: () -> Void
  @State private var isRenaming = false

  private var items: [CaptureHistoryEntry.Item] {
    Array(entry.availableItems.prefix(3))
  }

  private var stackCenterX: CGFloat {
    let edges = items.enumerated().map { index, item in
      let halfWidth = min(154, 144 * item.aspectRatio) / 2
      let center = Double(index) * 9
      return (left: center - halfWidth, right: center + halfWidth)
    }
    guard let left = edges.map(\.left).min(), let right = edges.map(\.right).max() else { return 0 }
    return CGFloat((left + right) / 2)
  }

  var body: some View {
    VStack(spacing: 6) {
      ZStack(alignment: .bottom) {
        if items.isEmpty {
          Image(systemName: entry.completedAt == nil ? entry.kind.symbol : "exclamationmark.triangle")
            .foregroundStyle(.secondary)
            .anchorPreference(key: CaptureHistoryGridBounds.self, value: .bounds) { .init(content: [$0]) }
        }
        ForEach(Array(items.enumerated().reversed()), id: \.element.id) { index, item in
          thumbnail(item, showsPlaybackIndicator: index == 0)
            .anchorPreference(key: CaptureHistoryGridBounds.self, value: .bounds) { .init(content: [$0]) }
            .offset(x: CGFloat(index) * 9, y: CGFloat(index) * -6)
        }
      }
      // Offsets do not affect layout, so center the visible bounds of the whole stack.
      .offset(x: -stackCenterX)
      .frame(width: 190, height: 156, alignment: .bottom)

      VStack(spacing: 0) {
        TimelineView(.periodic(from: .now, by: 60)) { context in
          HStack(spacing: 6) {
            Text(Self.relativeTime(entry.capturedAt, now: max(context.date, refreshedAt)))
            if entry.hasFailures { Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange) }
            if entry.completedAt == nil { ProgressView().controlSize(.mini) }
          }
          .font(.system(size: 12))
          .foregroundStyle(.secondary)
          .anchorPreference(key: CaptureHistoryGridBounds.self, value: .bounds) { .init(content: [$0]) }
        }

        CaptureHistoryName(entry: entry, isEditing: $isRenaming, rename: rename)
          .anchorPreference(key: CaptureHistoryGridBounds.self, value: .bounds) { .init(content: [$0]) }
      }
    }
    .frame(maxWidth: .infinity)
    .background {
      if isSelected {
        RoundedRectangle(cornerRadius: 8)
          .fill(Color.accentColor.opacity(0.15))
          .padding(-6)
      }
    }
    .contentShape(Rectangle())
    .onTapGesture(count: 2) {
      if !isRenaming { open() }
    }
    .simultaneousGesture(TapGesture().onEnded {
      if !isRenaming, !NSEvent.modifierFlags.contains(.control) { select() }
    })
    .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    .accessibilityAction(named: "Select", select)
    .accessibilityAction(named: "Open", open)
    .help([entry.frontItem?.deviceName, entry.capturedAt.formatted(date: .abbreviated, time: .shortened)]
      .compactMap(\.self).joined(separator: " · "))
    .contextMenu {
      Button("Rename") { isRenaming = true }
      Divider()
      Button("Delete…", role: .destructive, action: delete)
        .disabled(!canDelete)
    }
    .accessibilityElement(children: .contain)
    .accessibilityValue(entry.hasFailures ? "Some devices failed to capture" : "")
  }

  @ViewBuilder
  private func thumbnail(_ item: CaptureHistoryEntry.Item, showsPlaybackIndicator: Bool) -> some View {
    let thumbnail = CaptureHistoryThumbnail(
      entry: entry, item: item, root: root, showsPlaybackIndicator: showsPlaybackIndicator
    )
    .frame(width: min(154, 144 * item.aspectRatio), height: min(144, 154 / item.aspectRatio))
    if entry.availableItems.count == 1 {
      thumbnail.modifier(CaptureHistoryItemDrag(
        entry: entry, item: item, draggedMedia: $draggedMedia, dropPadding: 0, insertion: nil
      ) {
        exportFile(item)
      })
    } else {
      thumbnail
    }
  }

  static func relativeTime(_ date: Date, now: Date) -> String {
    let seconds = max(0, Int(now.timeIntervalSince(date)))
    if seconds < 60 { return "Just now" }
    if seconds < 3600 { return "\(seconds / 60)m ago" }
    if seconds < 86400 { return "\(seconds / 3600)h ago" }
    return "\(seconds / 86400)d ago"
  }
}
