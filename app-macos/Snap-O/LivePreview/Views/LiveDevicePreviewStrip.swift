import SwiftUI

struct LiveDevicePreviewStrip: View {
  let previews: [LivePreviewDevice]
  let selectedDeviceID: String?
  let attachment: LivePreviewAttachment?
  let loadSnapshot: (String) async throws -> Data
  let serverName: (Device) -> String?
  let selectDevice: (String) -> Void

  var body: some View {
    thumbnails
      .padding(.horizontal, 24)
      .padding(.vertical, 16)
      .background(RoundedRectangle(cornerRadius: 28, style: .continuous).fill(.ultraThinMaterial))
      .shadow(color: Color.black.opacity(0.25), radius: 10, x: 0, y: 6)
      .padding(.horizontal, 24)
  }

  var pickerContent: some View {
    ScrollView {
      VStack(spacing: 0) {
        ForEach(previews) { preview in
          DevicePickerRow(
            preview: preview, attachment: attachment?.target == preview.device.connection ? attachment : nil,
            loadSnapshot: loadSnapshot, serverName: serverName(preview.device),
            isSelected: preview.device.id == selectedDeviceID, selectDevice: selectDevice
          )
        }
      }
      .padding(6)
    }
    .frame(minWidth: 240, maxWidth: 420)
    .frame(maxHeight: 360)
    .fixedSize()
  }

  private var thumbnails: some View {
    HStack(spacing: 16) {
      ForEach(previews) { preview in
        let isSelected = preview.device.id == selectedDeviceID
        let server = serverName(preview.device)
        Button { selectDevice(preview.device.id) } label: {
          LiveDeviceThumbnail(
            preview: preview, attachment: attachment?.target == preview.device.connection ? attachment : nil,
            loadSnapshot: loadSnapshot, serverName: server, isSelected: isSelected
          )
        }
        .buttonStyle(.plain)
        .accessibilityLabel([preview.device.displayTitle, server].compactMap(\.self).joined(separator: " "))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
      }
    }
  }
}

private struct DevicePickerRow: View {
  let preview: LivePreviewDevice
  let attachment: LivePreviewAttachment?
  let loadSnapshot: (String) async throws -> Data
  let serverName: String?
  let isSelected: Bool
  let selectDevice: (String) -> Void
  @State private var isHovered = false

  var body: some View {
    let title = preview.device.displayTitle
    let aspect = preview.display?.aspectRatio ?? 9.0 / 16.0
    let height = min(44, 48 / aspect)
    let size = CGSize(width: height * aspect, height: height)
    let shape = RoundedRectangle(cornerRadius: 4)
    Button { selectDevice(preview.device.id) } label: {
      HStack(spacing: 10) {
        LivePreviewThumbnailView(attachment: attachment, isSelected: isSelected, size: size) {
          try await loadSnapshot(preview.device.id)
        }
        .frame(width: size.width, height: size.height)
        .clipShape(shape)
        .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
        .overlay { shape.strokeBorder(.primary.opacity(0.16), lineWidth: 0.5) }
        .frame(width: 48, height: 44)
        .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 2) {
          Text(title).font(.system(size: 13, weight: .medium))
          if let serverName {
            Text(serverName).font(.caption).foregroundStyle(.secondary)
          }
        }
        .lineLimit(1)
        .truncationMode(.tail)
        Spacer(minLength: 4)
        Image(systemName: "checkmark")
          .font(.system(size: 11, weight: .semibold))
          .opacity(isSelected ? 1 : 0)
          .accessibilityHidden(true)
      }
      .padding(.horizontal, 8)
      .padding(.vertical, 5)
      .contentShape(Rectangle())
      .background {
        if isHovered || isSelected {
          RoundedRectangle(cornerRadius: 5)
            .fill(.primary.opacity(isHovered ? 0.08 : 0.05))
        }
      }
    }
    .buttonStyle(.plain)
    .onHover { isHovered = $0 }
    .accessibilityLabel([title, serverName].compactMap(\.self).joined(separator: " "))
    .accessibilityAddTraits(isSelected ? .isSelected : [])
    .help([title, serverName].compactMap(\.self).joined(separator: " · "))
  }
}

private struct LiveDeviceThumbnail: View {
  let preview: LivePreviewDevice
  let attachment: LivePreviewAttachment?
  let loadSnapshot: (String) async throws -> Data
  let serverName: String?
  let isSelected: Bool
  @State private var isHovered = false

  var body: some View {
    let size = previewThumbnailSize(for: preview)
    let shape = RoundedRectangle(cornerRadius: 4, style: .continuous)
    LivePreviewThumbnailView(attachment: attachment, isSelected: isSelected, size: size) {
      try await loadSnapshot(preview.device.id)
    }
    .frame(width: size.width, height: size.height)
    .clipShape(shape)
    .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
    .overlay {
      shape.strokeBorder(.primary.opacity(isHovered ? 0.40 : 0.15), lineWidth: isHovered ? 1.5 : 0.5)
        .allowsHitTesting(false)
    }
    .overlay {
      if isSelected {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
          .stroke(Color.accentColor, lineWidth: isHovered ? 3 : 2)
          .allowsHitTesting(false)
      }
    }
    .contentShape(shape)
    .onHover { isHovered = $0 }
    .overlay(alignment: .bottom) {
      if isHovered {
        TextBubble(text: preview.device.displayTitle, subtitle: serverName)
          .fixedSize(horizontal: true, vertical: true)
          .frame(height: 0, alignment: .top)
          .offset(y: 4)
          .allowsHitTesting(false)
      }
    }
  }
}

private func previewThumbnailSize(for preview: LivePreviewDevice) -> CGSize {
  let aspectRatio = preview.display?.aspectRatio ?? 9.0 / 16.0
  return CGSize(width: min(max(80 * aspectRatio, 48), 200), height: 80)
}

private struct TextBubble: View {
  let text: String
  let subtitle: String?

  var body: some View {
    VStack(spacing: 2) {
      Text(text)
      if let subtitle {
        Text(subtitle)
          .font(.system(size: 11))
          .foregroundStyle(.secondary)
      }
    }
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
