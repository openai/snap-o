import SwiftUI
#if os(macOS)
import AppKit
#endif

struct NetworkInspectorView: View {
  @ObservedObject var store: NetworkInspectorStore
  @State private var selectedRequest: NetworkInspectorRequest.ID?

  var body: some View {
    NavigationView {
      List(selection: $selectedRequest) {
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

        Section("Requests") {
          if store.requests.isEmpty {
            Text("No requests yet")
              .foregroundStyle(.secondary)
          } else {
            ForEach(store.requests) { request in
              VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .center, spacing: 8) {
                  Text(request.method)
                    .font(.system(.caption, design: .monospaced))
                    .bold()
                    .foregroundStyle(.secondary)

                  VStack(alignment: .leading, spacing: 2) {
                    Text(request.primaryPathComponent)
                      .font(.subheadline.weight(.medium))
                      .lineLimit(1)
                    if !request.secondaryPath.isEmpty {
                      Text(request.secondaryPath)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    }
                  }

                  Spacer()

                  Text(statusLabel(for: request.status))
                    .font(.caption)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(statusColor(for: request.status).opacity(0.15))
                    .foregroundStyle(statusColor(for: request.status))
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
              }
              .padding(.vertical, 6)
              .contentShape(Rectangle())
              .tag(request.id)
            }
          }
        }
      }
      .frame(minWidth: 300, idealWidth: 340)
      .navigationTitle("Network Inspector")

      if let selection = selectedRequest,
         let detail = store.requestViewModel(for: selection) {
        NetworkInspectorRequestDetailView(request: detail)
      } else {
        VStack(alignment: .center, spacing: 12) {
          Text("Select a request")
            .font(.title2)
            .foregroundStyle(.secondary)
          Text("Choose a request from the list to inspect its headers.")
            .font(.body)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .onChange(of: store.requests.map(\.id)) { _, ids in
      guard !ids.isEmpty else {
        selectedRequest = nil
        return
      }

      if let selection = selectedRequest,
         ids.contains(selection) {
        return
      }

      selectedRequest = ids.first
    }
    .onAppear {
      if selectedRequest == nil {
        selectedRequest = store.requests.first?.id
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

        headerSection(title: "Request Headers", headers: request.requestHeaders)
        headerSection(title: "Response Headers", headers: request.responseHeaders)
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

  @ViewBuilder
  private func headerSection(title: String, headers: [NetworkInspectorRequestViewModel.Header]) -> some View {
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

private extension NetworkInspectorRequestDetailView {
#if os(macOS)
  func makeHeaderAttributedString(headers: [NetworkInspectorRequestViewModel.Header]) -> NSAttributedString {
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

  func appendValue(_ value: String, to line: NSMutableAttributedString, valueAttributes: [NSAttributedString.Key: Any]) {
    let components = value.split(separator: "\n", omittingEmptySubsequences: false)

    for (index, component) in components.enumerated() {
      if index > 0 {
        line.append(NSAttributedString(string: "\n\t", attributes: valueAttributes))
      }

      line.append(NSAttributedString(string: String(component), attributes: valueAttributes))
    }
  }
#endif
}

#if os(macOS)
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

    if let container = textView.textContainer {
      let width = max(textView.bounds.width, 1)
      container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
      textView.layoutManager?.ensureLayout(for: container)
    }

    textView.invalidateIntrinsicContentSize()
  }

  static func sizeThatFits(_ proposal: ProposedViewSize, nsView textView: NSTextView, context: Context) -> CGSize {
    guard let container = textView.textContainer else {
      return CGSize(width: proposal.width ?? 0, height: 0)
    }

    let inset = textView.textContainerInset
    let proposedWidth = proposal.width ?? textView.bounds.width
    let targetWidth = max(proposedWidth, 1)

    container.containerSize = NSSize(width: targetWidth, height: .greatestFiniteMagnitude)
    textView.layoutManager?.ensureLayout(for: container)
    let usedRect = textView.layoutManager?.usedRect(for: container) ?? .zero

    let height = ceil(usedRect.height) + inset.height * 2
    let width = proposal.width ?? ceil(usedRect.width) + inset.width * 2

    return CGSize(width: width, height: height)
  }
}
#endif
