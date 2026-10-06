import SwiftUI

struct CapturePaneTitle: View {
  let title: String
  let openDeviceManager: () -> Void

  var body: some View {
    HStack(spacing: 6) {
      Text(title).lineLimit(1).truncationMode(.tail)
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
