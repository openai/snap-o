import AppKit
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
        VStack(spacing: 8) {
          CapturePreviewStrip(controller: controller)

          if let title = controller.currentCaptureDeviceTitle {
            Text(title)
              .font(.system(size: 13, weight: .semibold))
              .padding(.horizontal, 16)
              .padding(.vertical, 8)
              .background(.ultraThinMaterial)
              .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
          }
        }
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
    return switch direction {
    case .previous: xTransition(insertion: .leading, removal: .trailing)
    case .next: xTransition(insertion: .trailing, removal: .leading)
    case .neutral: .opacity
    }
  }

  private func xTransition(insertion: Edge, removal: Edge) -> AnyTransition {
    return .asymmetric(
      insertion: .move(edge: insertion).combined(with: .opacity),
      removal: .move(edge: removal).combined(with: .opacity)
    )
  }
}

// MARK: - Preview Strip

private struct CapturePreviewStrip: View {
  @ObservedObject var controller: CaptureWindowController

  var body: some View {
      HStack(spacing: 16) {
        ForEach(controller.mediaList) { capture in
          Button {
            controller.selectMedia(id: capture.id, direction: .neutral)
          } label: {
            CapturePreviewThumbnail(
              capture: capture,
              isSelected: capture.id == controller.selectedMediaID
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
              .animation(.easeInOut(duration: 0.25), value: controller.selectedMediaID)
          }
        }
      }
  }
}

private struct CapturePreviewThumbnail: View {
  let capture: CaptureMedia
  let isSelected: Bool

  private let height: CGFloat = 64

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

  private var thumbnail: some View {
    switch capture.media {
    case .image(let url, _):
      if let image = NSImage(contentsOf: url) {
        return AnyView(
          Image(nsImage: image)
            .resizable()
            .scaledToFill()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        )
      } else {
        return AnyView(
          Color.gray
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        )
      }
    case .video:
      return AnyView(
        Color.gray.opacity(0.8)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      )
    case .livePreview:
      return AnyView(
        Color.black
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      )
    }
  }

  private var overlayContent: some View {
    switch capture.media {
    case .video:
      return AnyView(
        Image(systemName: "play.fill")
          .foregroundColor(.white)
          .font(.system(size: 20, weight: .semibold))
          .shadow(radius: 4)
      )
    default:
      return AnyView(EmptyView())
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
