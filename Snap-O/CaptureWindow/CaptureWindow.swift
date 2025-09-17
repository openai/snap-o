import AppKit
import AVFoundation
import SwiftUI

struct CaptureWindow: View {
  @StateObject private var controller = CaptureWindowController()

  var body: some View {
    ZStack {
      Color.black.ignoresSafeArea()

      let transition = transition(for: controller.transitionDirection)

      if controller.isDeviceListInitialized || controller.currentCapture != nil {
        CaptureMediaView(controller: controller)
          .id(controller.currentCaptureViewID)
          .transition(transition)
      } else {
        WaitingForDeviceView(isDeviceListInitialized: controller.isDeviceListInitialized)
          .transition(transition)
      }
    }
    .task { await controller.start() }
    .onDisappear { controller.tearDown() }
    .focusedSceneObject(controller)
    .navigationTitle(controller.navigationTitle)
    .toolbar {
      CaptureToolbar(controller: controller)

      if let progress = controller.captureProgressText {
        ToolbarItem(placement: .status) {
          Text(progress)
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .background(
              Capsule()
                .fill(.ultraThinMaterial)
                .padding(.horizontal, -6)
                .padding(.vertical, -4)
            )
            .onHover { controller.setProgressHovering($0) }
        }
      }
    }
    .overlay(alignment: .top) {
      if controller.mediaList.count > 1 {
        let captures = controller.overlayMediaList.isEmpty ? controller.mediaList : controller.overlayMediaList
        CapturePreviewStrip(
          captures: captures,
          selectedID: controller.selectedMediaID
        ) { controller.selectMedia(id: $0, direction: .neutral) }
        .opacity(controller.shouldShowPreviewHint ? 1 : 0)
        .offset(y: controller.shouldShowPreviewHint ? 0 : -20)
        .padding(.top, 12)
        .allowsHitTesting(controller.shouldShowPreviewHint)
        .onHover { controller.setPreviewHintHovering($0) }
        .animation(.easeInOut(duration: 0.35), value: controller.shouldShowPreviewHint)
      }
    }
    .animation(.snappy(duration: 0.25), value: controller.currentCaptureViewID)
  }
}

extension CaptureWindow {
  private func transition(for direction: DeviceTransitionDirection) -> AnyTransition {
    switch direction {
    case .previous: xTransition(insertion: .leading, removal: .trailing)
    case .next: xTransition(insertion: .trailing, removal: .leading)
    case .neutral: .opacity
    }
  }

  private func xTransition(insertion: Edge, removal: Edge) -> AnyTransition {
    .asymmetric(
      insertion: .move(edge: insertion).combined(with: .opacity),
      removal: .move(edge: removal).combined(with: .opacity)
    )
  }
}

// MARK: - Preview Strip

private struct CapturePreviewStrip: View {
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
          )
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
            .animation(.easeInOut(duration: 0.25), value: selectedID)
        }
      }
    }
  }
}

private struct CapturePreviewThumbnail: View {
  let capture: CaptureMedia
  let isSelected: Bool

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
    let targetTime = CMTime(seconds: 0, preferredTimescale: duration?.timescale == 0 ? 600 : duration?.timescale ?? 600)

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
