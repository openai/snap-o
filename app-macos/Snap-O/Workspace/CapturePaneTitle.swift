import SwiftUI

struct CapturePaneTitle: View {
  let title: String
  let serverName: String?
  let devicePicker: LiveDevicePicker
  let openDeviceManager: () -> Void
  @State private var isPickerPresented = false
  @State private var isPickerHovered = false
  @GestureState private var isDraggingWindow = false

  var body: some View {
    Button {
      isPickerPresented.toggle()
    } label: {
      HStack(spacing: 4) {
        deviceName
        Image(systemName: "chevron.down")
          .font(.system(size: 10, weight: .medium))
          .foregroundStyle(.secondary)
      }
      .padding(.horizontal, 12)
      .frame(height: 24)
      .glassEffect(!isDraggingWindow && (isPickerHovered || isPickerPresented) ? .regular.interactive() : .identity, in: Capsule())
      .frame(height: min(30, WindowChromeMetrics.titlebarHeight))
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    // A window drag consumes the click when the mouse button is released.
    .highPriorityGesture(
      WindowDragGesture().updating($isDraggingWindow) { _, isDragging, _ in isDragging = true }
    )
    .onHover { isPickerHovered = $0 }
    .help("Switch live preview device")
    .accessibilityLabel("Switch live preview device")
    .accessibilityValue(fullName)
    .popover(isPresented: $isPickerPresented, arrowEdge: .bottom) {
      VStack(spacing: 0) {
        devicePicker
        Divider()
        Button("Device Manager…") {
          isPickerPresented = false
          openDeviceManager()
        }
        .padding(10)
      }
    }
    .onDisappear { isPickerPresented = false }
    .font(.system(size: 13, weight: .semibold))
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private var deviceName: some View {
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
  }

  private var fullName: String {
    [title, serverName].compactMap(\.self).joined(separator: " ")
  }
}
