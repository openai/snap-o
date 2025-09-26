import SwiftUI

struct NetworkInspectorBodySection: View {
  let title: String
  let payload: NetworkInspectorRequestViewModel.BodyPayload
  @Binding private var isExpanded: Bool
  @State private var usePrettyPrinted: Bool

  init(title: String, payload: NetworkInspectorRequestViewModel.BodyPayload, isExpanded: Binding<Bool>) {
    self.title = title
    self.payload = payload
    _isExpanded = isExpanded
    _usePrettyPrinted = State(initialValue: false)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Button {
        isExpanded.toggle()
      } label: {
        HStack(spacing: 8) {
          Image(systemName: "chevron.right")
            .rotationEffect(isExpanded ? .degrees(90) : .zero)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)

          HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(title)
              .font(.headline)

            if let metadata = metadataText {
              Text(metadata)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          }
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)

      if isExpanded {
        InspectorCard {
          InspectorPayloadView(
            rawText: payload.rawText,
            prettyText: payload.prettyPrintedText,
            isLikelyJSON: payload.isLikelyJSON,
            usePrettyPrinted: $usePrettyPrinted,
            isExpandable: false
          )
        }
        .padding(.top, 8)
      }
    }
  }

  private var metadataText: String? {
    var parts: [String] = []

    if payload.capturedBytes > 0 {
      parts.append("Captured \(formatBytes(payload.capturedBytes))")
      if let total = payload.totalBytes {
        parts.append("of \(formatBytes(total))")
      }
    } else if let total = payload.totalBytes {
      parts.append("Total \(formatBytes(total))")
    }

    if let truncated = payload.truncatedBytes {
      if truncated > 0 {
        parts.append("(\(formatBytes(truncated)) truncated)")
      } else if truncated == 0, !payload.isPreview {
        parts.append("(complete)")
      }
    } else if payload.isPreview {
      parts.append("(preview)")
    }

    guard !parts.isEmpty else { return nil }
    return parts.joined(separator: " ")
  }
}

private func formatBytes(_ byteCount: Int64) -> String {
  let formatter = ByteCountFormatter()
  formatter.countStyle = .binary
  return formatter.string(fromByteCount: byteCount)
}
