import SwiftUI

struct NetworkInspectorBodySection: View {
  let title: String
  let payload: NetworkInspectorRequestViewModel.BodyPayload
  @State private var isExpanded: Bool
  @State private var usePrettyPrinted: Bool

  init(title: String, payload: NetworkInspectorRequestViewModel.BodyPayload) {
    self.title = title
    self.payload = payload
    _isExpanded = State(initialValue: false)
    _usePrettyPrinted = State(initialValue: payload.prettyPrintedText != nil)
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
        VStack(alignment: .leading, spacing: 8) {
          if payload.prettyPrintedText != nil {
            Toggle("Pretty print JSON", isOn: $usePrettyPrinted)
              .font(.caption)
          } else if payload.isLikelyJSON {
            Text("Unable to pretty print (invalid or truncated JSON)")
              .font(.caption)
              .foregroundStyle(.secondary)
          }

          Text(displayText)
            .font(.body.monospaced())
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Color.secondary.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
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

  private var displayText: String {
    if usePrettyPrinted, let pretty = payload.prettyPrintedText {
      return pretty
    }
    return payload.rawText
  }
}

private func formatBytes(_ byteCount: Int64) -> String {
  let formatter = ByteCountFormatter()
  formatter.countStyle = .binary
  return formatter.string(fromByteCount: byteCount)
}
