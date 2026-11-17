import SwiftUI

struct LiveDevicePicker: View {
  let previews: [LivePreviewDevice]
  let selectedDeviceID: String?
  let attachment: LivePreviewAttachment?
  let loadSnapshot: (String) async throws -> Data
  let serverName: (Device) -> String?
  let selectDevice: (String) -> Void

  var body: some View {
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
}

private struct DevicePickerRow: View {
  let preview: LivePreviewDevice
  let attachment: LivePreviewAttachment?
  let loadSnapshot: (String) async throws -> Data
  let serverName: String?
  let isSelected: Bool
  let selectDevice: (String) -> Void
  @Environment(\.dismiss)
  private var dismiss
  @State private var isHovered = false

  var body: some View {
    let title = preview.device.displayTitle
    let aspect = preview.display?.aspectRatio ?? 9.0 / 16.0
    let height = min(44, 48 / aspect)
    let size = CGSize(width: height * aspect, height: height)
    let shape = RoundedRectangle(cornerRadius: 4)
    Button {
      selectDevice(preview.device.id)
      dismiss()
    } label: {
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
