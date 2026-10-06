import SwiftUI

private struct PreviewStrip<Content: View>: View {
  @ViewBuilder var content: Content

  var body: some View {
    HStack(spacing: 16) { content }
      .padding(.horizontal, 24)
      .padding(.vertical, 16)
      .background(RoundedRectangle(cornerRadius: 28, style: .continuous).fill(.ultraThinMaterial))
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

struct LiveDevicePreviewStrip: View {
  let previews: [LivePreviewDevice]
  let selectedDeviceID: String?
  let attachment: LivePreviewAttachment?
  let loadSnapshot: (String) async throws -> Data
  let selectDevice: (String) -> Void

  var body: some View {
    PreviewStrip {
      ForEach(previews) { preview in
        Button { selectDevice(preview.device.id) } label: {
          LiveDeviceThumbnail(
            preview: preview, attachment: attachment?.target == preview.device.connection ? attachment : nil,
            loadSnapshot: loadSnapshot, isSelected: preview.device.id == selectedDeviceID
          )
        }
        .buttonStyle(.plain)
      }
    }
  }
}

private struct LiveDeviceThumbnail: View {
  let preview: LivePreviewDevice
  let attachment: LivePreviewAttachment?
  let loadSnapshot: (String) async throws -> Data
  let isSelected: Bool
  @State private var isHovered = false

  var body: some View {
    let size = CGSize(width: previewThumbnailWidth(aspectRatio: preview.display?.aspectRatio ?? 9.0 / 16.0, height: 80), height: 80)
    LivePreviewThumbnailView(attachment: attachment, isSelected: isSelected, size: size) {
      try await loadSnapshot(preview.device.id)
    }
    .frame(width: size.width, height: size.height)
    .clipped()
    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
    .anchorPreference(key: PreviewSelectionBoundsKey.self, value: .bounds) { isSelected ? $0 : nil }
    .onHover { isHovered = $0 }
    .overlay(alignment: .bottom) {
      if isHovered {
        TextBubble(text: preview.device.displayTitle)
          .fixedSize(horizontal: true, vertical: true)
          .offset(y: 32)
          .allowsHitTesting(false)
      }
    }
  }
}

private func previewThumbnailWidth(aspectRatio: CGFloat, height: CGFloat) -> CGFloat {
  min(max(height * max(aspectRatio, 0.1), height * 0.6), height * 2.5)
}

private struct PreviewSelectionBoundsKey: PreferenceKey {
  static let defaultValue: Anchor<CGRect>? = nil

  static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
    if let next = nextValue() {
      value = next
    }
  }
}

private struct TextBubble: View {
  let text: String

  var body: some View {
    Text(text)
      .multilineTextAlignment(.center)
      .font(.system(size: 13, weight: .medium))
      .padding(.horizontal, 14)
      .padding(.vertical, 6)
      .background(
        RoundedRectangle(cornerRadius: 16, style: .continuous)
          .fill(.ultraThinMaterial)
      )
  }
}
