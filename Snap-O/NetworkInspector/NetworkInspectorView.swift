import Foundation
import SwiftUI
#if os(macOS)
import AppKit
#endif

struct NetworkInspectorView: View {
  @ObservedObject var store: NetworkInspectorStore
  @State private var selectedItem: NetworkInspectorItemID?

  var body: some View {
    NavigationView {
      List(selection: $selectedItem) {
        Section("Servers") {
          if store.servers.isEmpty {
            Text("No active servers")
              .foregroundStyle(.secondary)
          } else {
            ForEach(store.servers) { server in
              VStack(alignment: .leading, spacing: 2) {
                Text(server.displayName)
                  .font(.headline)
                if let hello = server.helloSummary {
                  Text(hello)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
              }
            }
          }
        }

        Section("Requests & WebSockets") {
          if store.items.isEmpty {
            Text("No activity yet")
              .foregroundStyle(.secondary)
          } else {
            ForEach(store.items) { item in
              VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .center, spacing: 8) {
                  Text(item.method)
                    .font(.system(.caption, design: .monospaced))
                    .bold()
                    .foregroundStyle(.secondary)

                  VStack(alignment: .leading, spacing: 2) {
                    Text(item.primaryPathComponent)
                      .font(.subheadline.weight(.medium))
                      .lineLimit(1)
                    if !item.secondaryPath.isEmpty {
                      Text(item.secondaryPath)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    }
                  }

                  Spacer()

                  Text(statusLabel(for: item.status))
                    .font(.caption)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(statusColor(for: item.status).opacity(0.15))
                    .foregroundStyle(statusColor(for: item.status))
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
              }
              .padding(.vertical, 6)
              .contentShape(Rectangle())
              .tag(item.id)
            }
          }
        }
      }
      .frame(minWidth: 300, idealWidth: 340)
      .navigationTitle("Network Inspector")

      if let selection = selectedItem,
         let detail = store.detail(for: selection) {
        switch detail {
        case .request(let request):
          NetworkInspectorRequestDetailView(request: request)
        case .webSocket(let webSocket):
          NetworkInspectorWebSocketDetailView(webSocket: webSocket)
        }
      } else {
        VStack(alignment: .center, spacing: 12) {
          Text("Select a record")
            .font(.title2)
            .foregroundStyle(.secondary)
          Text("Choose an entry to inspect its details.")
            .font(.body)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .onChange(of: store.items.map(\.id)) { _, ids in
      guard !ids.isEmpty else {
        selectedItem = nil
        return
      }

      if let selection = selectedItem,
         ids.contains(selection) {
        return
      }

      selectedItem = ids.first
    }
    .onAppear {
      if selectedItem == nil {
        selectedItem = store.items.first?.id
      }
    }
  }

  private func statusLabel(for status: NetworkInspectorRequestViewModel.Status) -> String {
    switch status {
    case .pending:
      return "Pending"
    case .success(let code):
      return "\(code)"
    case .failure:
      return "Failed"
    }
  }

  private func statusColor(for status: NetworkInspectorRequestViewModel.Status) -> Color {
    switch status {
    case .pending:
      return .secondary
    case .success:
      return .green
    case .failure:
      return .red
    }
  }
}

private struct NetworkInspectorRequestDetailView: View {
  let request: NetworkInspectorRequestViewModel

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        headerSummary

        NetworkInspectorHeadersSection(title: "Request Headers", headers: request.requestHeaders)
        NetworkInspectorHeadersSection(title: "Response Headers", headers: request.responseHeaders)
      }
      .padding(24)
    }
  }

  private var headerSummary: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .firstTextBaseline) {
        Text(request.method)
          .font(.title3.weight(.semibold))
          .textSelection(.enabled)
        Text(request.url)
          .font(.body)
          .textSelection(.enabled)
      }

      HStack(spacing: 12) {
        statusBadge
        Text(request.requestIdentifier)
          .font(.callout)
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
      }

      if case .failure(let message) = request.status, let message, !message.isEmpty {
        Text("Error: \(message)")
          .font(.callout)
          .foregroundStyle(.red)
          .textSelection(.enabled)
      }

      Text(request.serverSummary)
        .font(.callout)
        .foregroundStyle(.secondary)
        .textSelection(.enabled)

      Text(request.timingSummary)
        .font(.footnote)
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
    }
  }

  private var statusBadge: some View {
    let label: String
    let color: Color

    switch request.status {
    case .pending:
      label = "Pending"
      color = .secondary
    case .success(let code):
      label = "Success (\(code))"
      color = .green
    case .failure:
      label = "Failed"
      color = .red
    }

    return Text(label)
      .font(.caption)
      .padding(.horizontal, 8)
      .padding(.vertical, 4)
      .background(color.opacity(0.15))
      .foregroundStyle(color)
      .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
  }
}

private struct NetworkInspectorWebSocketDetailView: View {
  let webSocket: NetworkInspectorWebSocketViewModel

  var body: some View {
    ScrollView {
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
      HStack(alignment: .firstTextBaseline) {
        Text(webSocket.method)
          .font(.title3.weight(.semibold))
          .textSelection(.enabled)
        Text(webSocket.url)
          .font(.body)
          .textSelection(.enabled)
      }

      HStack(spacing: 12) {
        statusBadge
        Text(webSocket.socketIdentifier)
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
        Text("Close requested: \(closeRequested.code) • \(closeRequested.initiated.capitalized) • \(closeRequested.accepted ? "accepted" : "not accepted")")
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

      Text(webSocket.serverSummary)
        .font(.callout)
        .foregroundStyle(.secondary)
        .textSelection(.enabled)

      Text(webSocket.timingSummary)
        .font(.footnote)
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
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
      HStack(spacing: 8) {
        directionBadge(for: message)
        Text(message.timestamp.formatted(date: .omitted, time: .standard))
          .font(.caption)
          .foregroundStyle(.secondary)
        Spacer()
        Text(message.opcode)
          .font(.caption.monospaced())
          .foregroundStyle(.secondary)
      }

      if let preview = message.preview, !preview.isEmpty {
        Text(preview)
          .font(.body.monospaced())
          .textSelection(.enabled)
      }

      HStack(spacing: 12) {
        if let size = message.payloadSize {
          Text("Payload: \(formatBytes(size))")
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        if let enqueued = message.enqueued {
          Text(enqueued ? "Enqueued" : "Immediate")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color.secondary.opacity(0.08))
    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
  }

  private func directionBadge(for message: NetworkInspectorWebSocketViewModel.Message) -> some View {
    let color: Color = message.direction == .outgoing ? .blue : .green
    let label = message.direction == .outgoing ? "OUT" : "IN"

    return Text(label)
      .font(.caption.weight(.semibold))
      .padding(.horizontal, 6)
      .padding(.vertical, 2)
      .background(color.opacity(0.15))
      .foregroundStyle(color)
      .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
  }
}

private struct NetworkInspectorHeadersSection: View {
  let title: String
  let headers: [NetworkInspectorRequestViewModel.Header]

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(title)
        .font(.headline)

      if headers.isEmpty {
        Text("None")
          .font(.subheadline)
          .foregroundStyle(.secondary)
      } else {
#if os(macOS)
        SelectableHeaderList(attributedString: makeHeaderAttributedString(headers: headers))
          .frame(maxWidth: .infinity, alignment: .leading)
          .fixedSize(horizontal: false, vertical: true)
#else
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
          ForEach(headers) { header in
            GridRow(alignment: .firstTextBaseline) {
              Text(header.name)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
              Text(header.value)
                .font(.callout)
                .textSelection(.enabled)
            }
          }
        }
#endif
      }
    }
  }
}

private func formatBytes(_ byteCount: Int64) -> String {
  let formatter = ByteCountFormatter()
  formatter.countStyle = .binary
  return formatter.string(fromByteCount: byteCount)
}

#if os(macOS)
private func makeHeaderAttributedString(headers: [NetworkInspectorRequestViewModel.Header]) -> NSAttributedString {
  guard !headers.isEmpty else { return NSAttributedString() }

  let captionFont = NSFont.preferredFont(forTextStyle: .caption1)
  let nameFont = NSFont.systemFont(ofSize: captionFont.pointSize, weight: .semibold)
  let valueFont = NSFont.preferredFont(forTextStyle: .body)
  let secondaryColor = NSColor.secondaryLabelColor
  let primaryColor = NSColor.labelColor

  let nameAttributes: [NSAttributedString.Key: Any] = [
    .font: nameFont,
    .foregroundColor: secondaryColor
  ]

  let valueAttributes: [NSAttributedString.Key: Any] = [
    .font: valueFont,
    .foregroundColor: primaryColor
  ]

  let widestName = headers
    .map { header -> CGFloat in
      (header.name as NSString).size(withAttributes: [.font: nameFont]).width
    }
    .max() ?? 0

  let tabLocation = widestName.rounded(.up) + 16

  let paragraphStyle = NSMutableParagraphStyle()
  paragraphStyle.tabStops = [NSTextTab(textAlignment: .left, location: tabLocation)]
  paragraphStyle.defaultTabInterval = tabLocation
  paragraphStyle.lineSpacing = 2
  paragraphStyle.paragraphSpacing = 6
  paragraphStyle.firstLineHeadIndent = 0
  paragraphStyle.headIndent = tabLocation
  paragraphStyle.lineBreakMode = .byWordWrapping

  let result = NSMutableAttributedString()

  for (index, header) in headers.enumerated() {
    let line = NSMutableAttributedString()
    line.append(NSAttributedString(string: header.name, attributes: nameAttributes))
    line.append(NSAttributedString(string: "\t", attributes: valueAttributes))
    appendValue(header.value, to: line, valueAttributes: valueAttributes)

    if index < headers.count - 1 {
      line.append(NSAttributedString(string: "\n", attributes: valueAttributes))
    }

    line.addAttribute(.paragraphStyle, value: paragraphStyle, range: NSRange(location: 0, length: line.length))
    result.append(line)
  }

  return result
}

private func appendValue(_ value: String, to line: NSMutableAttributedString, valueAttributes: [NSAttributedString.Key: Any]) {
  let components = value.split(separator: "\n", omittingEmptySubsequences: false)

  for (index, component) in components.enumerated() {
    if index > 0 {
      line.append(NSAttributedString(string: "\n\t", attributes: valueAttributes))
    }

    line.append(NSAttributedString(string: String(component), attributes: valueAttributes))
  }
}

private struct SelectableHeaderList: NSViewRepresentable {
  let attributedString: NSAttributedString

  func makeNSView(context: Context) -> NSTextView {
    let textView = NSTextView()
    textView.isEditable = false
    textView.isSelectable = true
    textView.drawsBackground = false
    textView.backgroundColor = .clear
    textView.textContainerInset = .zero
    textView.isHorizontallyResizable = false
    textView.isVerticallyResizable = false
    textView.minSize = NSSize(width: 0, height: 0)
    textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    textView.setContentHuggingPriority(.defaultLow, for: .horizontal)
    textView.setContentHuggingPriority(.defaultHigh, for: .vertical)
    textView.setContentCompressionResistancePriority(.required, for: .vertical)

    if let container = textView.textContainer {
      container.lineFragmentPadding = 0
      container.widthTracksTextView = false
      container.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
    }

    textView.linkTextAttributes = [:]
    textView.textStorage?.setAttributedString(attributedString)
    return textView
  }

  func updateNSView(_ textView: NSTextView, context: Context) {
    let previousSelection = textView.selectedRange()
    textView.textStorage?.setAttributedString(attributedString)

    let length = attributedString.length
    let clampedLocation = min(previousSelection.location, length)
    let remainingLength = max(length - clampedLocation, 0)
    let clampedLength = min(previousSelection.length, remainingLength)
    textView.setSelectedRange(NSRange(location: clampedLocation, length: clampedLength))

    textView.invalidateIntrinsicContentSize()
  }

  func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSTextView, context: Context) -> CGSize? {
    guard let textContainer = nsView.textContainer else {
      return CGSize(width: proposal.width ?? 0, height: 0)
    }

    let inset = nsView.textContainerInset
    let proposedWidth = proposal.width ?? nsView.bounds.width
    let targetWidth = max(proposedWidth - inset.width * 2, 1)

    textContainer.containerSize = NSSize(width: targetWidth, height: .greatestFiniteMagnitude)
    nsView.layoutManager?.ensureLayout(for: textContainer)
    let usedRect = nsView.layoutManager?.usedRect(for: textContainer) ?? .zero

    let width = proposal.width ?? ceil(usedRect.width) + inset.width * 2
    let height = ceil(usedRect.height) + inset.height * 2

    return CGSize(width: width, height: height)
  }
}
#endif
