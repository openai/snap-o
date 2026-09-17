import SwiftUI

struct CapturePaneTitle: View {
  let entry: CaptureHistoryEntry?
  let deviceTitle: String?
  let fallbackTitle: String
  let rename: (String) -> Void

  var body: some View {
    HStack(spacing: 6) {
      if let entry {
        CaptureNameButton(entry: entry, rename: rename)
          .layoutPriority(1)
      } else {
        Text(fallbackTitle).lineLimit(1)
      }
      if let deviceTitle {
        Text("— \(deviceTitle)")
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.tail)
      }
    }
    .simultaneousGesture(WindowDragGesture())
    .font(.system(size: 13, weight: .semibold))
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}
