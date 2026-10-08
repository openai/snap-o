import SwiftUI

struct CapturePaneTitle: View {
  let title: String
  let serverName: String?
  let openDeviceManager: () -> Void

  var body: some View {
    HStack(spacing: 6) {
      HStack(spacing: 6) {
        Text(title)
          .truncationMode(.tail)
        if let serverName {
          Text(serverName)
            .fontWeight(.regular)
            .foregroundStyle(.secondary)
            .truncationMode(.middle)
        }
      }
      .lineLimit(1)
      .help([title, serverName].compactMap(\.self).joined(separator: " "))
      Button(action: openDeviceManager) {
        Image(systemName: "ellipsis")
          .font(.system(size: 13, weight: .regular))
          .frame(width: 20, height: 20)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .foregroundStyle(.secondary)
      .fixedSize()
      .help("Device Manager")
      .accessibilityLabel("Device Manager")
    }
    .simultaneousGesture(WindowDragGesture())
    .font(.system(size: 13, weight: .semibold))
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}
