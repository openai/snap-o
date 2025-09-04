import AppKit
import SwiftUI

/// Places a compact, custom title on the leading side with a chevron-only
/// button to switch devices via a popover. The native window title is hidden
/// elsewhere so this becomes the sole title UI.
struct TitleDevicePickerToolbar: ToolbarContent {
  @ObservedObject var controller: CaptureController
  let isDeviceListInitialized: Bool

  var body: some ToolbarContent {
    ToolbarItem(placement: .navigation) {
      TitleDeviceTitleView(controller: controller, isDeviceListInitialized: isDeviceListInitialized)
    }
    // Flexible spacer to push primaryAction items to the trailing edge.
    ToolbarItem(placement: .automatic) {
      Spacer(minLength: 0)
    }
  }
}

private struct TitleDeviceTitleView: View {
  @ObservedObject var controller: CaptureController
  let isDeviceListInitialized: Bool
  @State private var showPicker = false

  private var selectedDevice: Device? { controller.devices.currentDevice }
  private var primaryTitle: String { selectedDevice?.displayTitle ?? "Snap‑O" }
  private var showChevron: Bool { controller.devices.available.count > 1 }

  var body: some View {
    HStack(spacing: 6) {
      Text(primaryTitle)
        .font(.system(size: 15, weight: .semibold))
        .lineLimit(1)
        .truncationMode(.tail)

      if showChevron {
        Button {
          showPicker.toggle()
        } label: {
          Image(systemName: "chevron.down")
            .font(.system(size: 10, weight: .semibold))
            .imageScale(.small)
            .padding(.horizontal, 2)
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showPicker, arrowEdge: .bottom) {
          DevicePickerList(
            controller: controller,
            isPresented: $showPicker,
            isDeviceListInitialized: isDeviceListInitialized
          )
          .frame(minWidth: 260)
          .padding(8)
        }
      }
    }
    .frame(maxWidth: 420, alignment: .leading)
    .fixedSize(horizontal: false, vertical: true)
  }
}

private struct DevicePickerList: View {
  @ObservedObject var controller: CaptureController
  @Binding var isPresented: Bool
  let isDeviceListInitialized: Bool

  var body: some View {
    let devices = controller.devices.available
    let currentID = controller.devices.selectedID
    let currentIndex = devices.firstIndex { $0.id == currentID }

    return VStack(alignment: .leading, spacing: 4) {
      if devices.isEmpty {
        if !isDeviceListInitialized {
          HStack {
            ProgressView()
              .controlSize(.small)
            Text("Loading devices…")
              .foregroundStyle(.secondary)
          }
          .padding(6)
        } else {
          Text("Waiting for device...")
            .foregroundStyle(.secondary)
            .padding(6)
        }
      } else {
        ForEach(Array(devices.enumerated()), id: \.element.id) { index, device in
          let isSelected = (device.id == currentID)
          let showUpHint = currentIndex.map { index == $0 - 1 } ?? false
          let showDownHint = currentIndex.map { index == $0 + 1 } ?? false

          Button {
            controller.devices.selectedID = device.id
            isPresented = false
          } label: {
            HStack(spacing: 8) {
              // Reserve space for checkmark to keep rows aligned
              Image(systemName: "checkmark")
                .opacity(isSelected ? 1 : 0)
              Text(device.displayTitle)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
              Spacer(minLength: 12)
              if showUpHint {
                Text("⌘▲").font(.caption2).foregroundStyle(.secondary)
              } else if showDownHint {
                Text("⌘▼").font(.caption2).foregroundStyle(.secondary)
              }
            }
            .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .background(
            RoundedRectangle(cornerRadius: 6)
              .fill(Color.primary.opacity(0.06))
              .opacity(isSelected ? 1 : 0)
          )
        }
      }
    }
  }
}
