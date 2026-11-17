import SwiftUI

struct CapturePaneTitle: View {
  let title: String
  let serverName: String?
  let devicePicker: LiveDevicePreviewStrip?
  @Binding var isPickerPresented: Bool
  let openDeviceManager: () -> Void
  @State private var isPickerHovered = false

  var body: some View {
    Group {
      if let devicePicker {
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
          .glassEffect(isPickerHovered || isPickerPresented ? .regular.interactive() : .identity, in: Capsule())
          .frame(height: min(30, WindowChromeMetrics.titlebarHeight))
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isPickerHovered = $0 }
        .help("Switch live preview device")
        .accessibilityLabel("Switch live preview device")
        .accessibilityValue(fullName)
        .popover(isPresented: $isPickerPresented, arrowEdge: .bottom) {
          VStack(spacing: 0) {
            devicePicker.pickerContent
            Divider()
            Button("Device Manager…") {
              isPickerPresented = false
              openDeviceManager()
            }
            .padding(10)
          }
        }
        .onDisappear { isPickerPresented = false }
      } else {
        HStack(spacing: 6) {
          deviceName
            .help(fullName)
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
      }
    }
    .simultaneousGesture(WindowDragGesture())
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
