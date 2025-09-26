import SwiftUI

struct NetworkInspectorWebSocketDetailView: View {
  let webSocket: NetworkInspectorWebSocketViewModel
  let onClose: () -> Void

  var body: some View {
    ScrollView(.vertical) {
      VStack(alignment: .leading, spacing: 16) {
        headerSummary

        NetworkInspectorHeadersSection(title: "Request Headers", headers: webSocket.requestHeaders)
        NetworkInspectorHeadersSection(title: "Response Headers", headers: webSocket.responseHeaders)

        messagesSection
      }
      .padding(24)
    }
  }

  private var headerSummary: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .top, spacing: 12) {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
          Text(webSocket.method)
            .font(.title3.weight(.semibold))
            .textSelection(.enabled)
          Text(webSocket.url)
            .font(.body)
            .textSelection(.enabled)
        }
        Spacer()
        Button(action: onClose) {
          Image(systemName: "xmark")
            .font(.title2)
            .symbolRenderingMode(.hierarchical)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("Close web socket detail")
      }

      HStack(spacing: 12) {
        statusBadge
        Text(webSocket.timingSummary)
          .font(.callout)
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
      }

      if case .failure(let message) = webSocket.status, let message, !message.isEmpty {
        Text("Error: \(message)")
          .font(.callout)
          .foregroundStyle(.red)
          .textSelection(.enabled)
      }

      if let closeRequested = webSocket.closeRequested {
        Text(
          "Close requested: \(closeRequested.code) • \(closeRequested.initiated.capitalized) • \(closeRequested.accepted ? "accepted" : "not accepted")"
        )
        .font(.callout)
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
        if let reason = closeRequested.reason, !reason.isEmpty {
          Text("Reason: \(reason)")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
        }
      }

      if let closing = webSocket.closing {
        Text("Closing handshake: \(closing.code)")
          .font(.callout)
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
        if let reason = closing.reason, !reason.isEmpty {
          Text("Reason: \(reason)")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
        }
      }

      if let closed = webSocket.closed {
        Text("Closed: \(closed.code)")
          .font(.callout)
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
        if let reason = closed.reason, !reason.isEmpty {
          Text("Reason: \(reason)")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
        }
      }

      if webSocket.cancelled != nil {
        Text("Cancelled")
          .font(.callout)
          .foregroundStyle(.secondary)
      }
    }
  }

  private var statusBadge: some View {
    let label: String
    let color: Color

    if let closed = webSocket.closed {
      label = "Closed (\(closed.code))"
      color = .green
    } else if let closing = webSocket.closing {
      label = "Closing (\(closing.code))"
      color = .green
    } else if let opened = webSocket.opened {
      label = "Open (\(opened.code))"
      color = .green
    } else {
      switch webSocket.status {
      case .pending:
        label = "Pending"
        color = .secondary
      case .success(let code):
        label = "Code \(code)"
        color = .green
      case .failure:
        label = "Failed"
        color = .red
      }
    }

    return Text(label)
      .font(.caption)
      .padding(.horizontal, 8)
      .padding(.vertical, 4)
      .background(color.opacity(0.15))
      .foregroundStyle(color)
      .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
  }

  private var messagesSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Messages")
        .font(.headline)

      if webSocket.messages.isEmpty {
        Text("No messages yet")
          .font(.subheadline)
          .foregroundStyle(.secondary)
      } else {
        LazyVStack(alignment: .leading, spacing: 12) {
          ForEach(webSocket.messages) { message in
            messageCard(for: message)
          }
        }
      }
    }
  }

  private func messageCard(for message: NetworkInspectorWebSocketViewModel.Message) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 4) {
        directionBadge(for: message)
        if let size = message.payloadSize {
          Text("\(formatBytes(size))")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
        if let enqueued = message.enqueued {
          Text(enqueued ? "Enqueued" : "Immediate")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Text(message.timestamp.formatted(date: .omitted, time: .standard))
          .font(.caption)
          .foregroundStyle(.secondary)
        Text(message.opcode)
          .font(.caption.monospaced())
          .foregroundStyle(.secondary)
      }

      if let preview = message.preview, !preview.isEmpty {
        Text(preview)
          .font(.caption.monospaced())
          .textSelection(.enabled)
      }
    }
    .padding(.horizontal, 6)
    .padding(.vertical, 4)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color.secondary.opacity(0.08))
    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
  }

  private func directionBadge(for message: NetworkInspectorWebSocketViewModel.Message) -> some View {
    let color: Color = message.direction == .outgoing ? .blue : .green
    let symbolName = message.direction == .outgoing ? "tray" : "paperplane"

    return Image(systemName: symbolName)
      .font(.caption.weight(.semibold))
      .symbolRenderingMode(.hierarchical)
      .foregroundStyle(color)
  }
}

private func formatBytes(_ byteCount: Int64) -> String {
  let formatter = ByteCountFormatter()
  formatter.countStyle = .binary
  return formatter.string(fromByteCount: byteCount)
}
