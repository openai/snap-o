import SwiftUI

struct TitleCapturePickerToolbar: ToolbarContent {
  @ObservedObject var controller: CaptureWindowController

  var body: some ToolbarContent {
    ToolbarItem(placement: .navigation) {
      TitleCapturePicker(controller: controller)
    }
    ToolbarItem(placement: .automatic) {
      Spacer(minLength: 0)
    }
  }
}

private struct TitleCapturePicker: View {
  @ObservedObject var controller: CaptureWindowController
  @State private var showPicker = false

  private var selectedCapture: CaptureMedia? { controller.currentCapture }
  private var primaryTitle: String { selectedCapture?.device.displayTitle ?? "Snap‑O" }
  private var showChevron: Bool { controller.hasAlternativeMedia() }

  var body: some View {
    HStack(spacing: 6) {
      Text(primaryTitle)
        .font(.system(size: 15, weight: .semibold))
        .lineLimit(1)
        .truncationMode(.tail)

      if showChevron {
        Button { showPicker.toggle() } label: {
          Image(systemName: "chevron.down")
            .font(.system(size: 10, weight: .semibold))
            .imageScale(.small)
            .padding(.horizontal, 2)
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showPicker, arrowEdge: .bottom) {
          CapturePickerList(controller: controller, isPresented: $showPicker)
            .frame(minWidth: 260)
            .padding(8)
        }
      }
    }
    .frame(maxWidth: 420, alignment: .leading)
    .fixedSize(horizontal: false, vertical: true)
  }
}

private struct CapturePickerList: View {
  @ObservedObject var controller: CaptureWindowController
  @Binding var isPresented: Bool

  var body: some View {
    let mediaList = controller.mediaList
    let currentID = controller.currentCapture?.id
    let currentIndex = mediaList.firstIndex { $0.id == currentID }

    VStack(alignment: .leading, spacing: 4) {
      if mediaList.isEmpty {
        Text("Capture all connected devices to begin.")
          .foregroundStyle(.secondary)
          .padding(6)
      } else {
        ForEach(Array(mediaList.enumerated()), id: \.element.id) { index, capture in
          let isSelected = (capture.id == currentID)
          let showUpHint = currentIndex.map { index == $0 - 1 } ?? false
          let showDownHint = currentIndex.map { index == $0 + 1 } ?? false

          Button {
            controller.selectMedia(id: capture.id, direction: .neutral)
            isPresented = false
          } label: {
            HStack(spacing: 8) {
              Image(systemName: "checkmark").opacity(isSelected ? 1 : 0)
              VStack(alignment: .leading, spacing: 2) {
                Text(capture.device.displayTitle)
                  .foregroundStyle(.primary)
                  .lineLimit(1)
                  .truncationMode(.tail)
                Text(capture.media.capturedAt, style: .time)
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }
              Spacer(minLength: 12)
              if showUpHint {
                Text("⌘▲").font(.caption2).foregroundStyle(.secondary)
              } else if showDownHint {
                Text("⌘▼").font(.caption2).foregroundStyle(.secondary)
              }
            }
            .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
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
