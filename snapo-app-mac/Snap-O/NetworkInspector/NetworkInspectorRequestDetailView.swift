import SwiftUI

struct NetworkInspectorRequestDetailView: View {
  @ObservedObject var store: NetworkInspectorStore
  let request: NetworkInspectorRequestViewModel
  let onClose: () -> Void

  var body: some View {
    ScrollView(.vertical) {
      VStack(alignment: .leading, spacing: 16) {
        headerSummary

        NetworkInspectorHeadersSection(
          title: "Request Headers",
          headers: request.requestHeaders,
          isExpanded: sectionBinding(for: .requestHeaders)
        )

        if let requestBody = request.requestBody {
          NetworkInspectorBodySection(
            title: "Request Body",
            payload: requestBody,
            isExpanded: sectionBinding(for: .requestBody)
          )
        }

        NetworkInspectorHeadersSection(
          title: "Response Headers",
          headers: request.responseHeaders,
          isExpanded: sectionBinding(for: .responseHeaders)
        )

        if request.isStreamingResponse {
          StreamEventsSection(
            events: request.streamEvents,
            closed: request.streamClosed,
            isExpanded: sectionBinding(for: .stream)
          )
        }

        if let responseBody = request.responseBody {
          NetworkInspectorBodySection(
            title: "Response Body",
            payload: responseBody,
            isExpanded: sectionBinding(for: .responseBody)
          )
        }
      }
      .padding(24)
    }
  }

  private var headerSummary: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .top, spacing: 12) {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
          Text(request.method)
            .font(.title3.weight(.semibold))
            .textSelection(.enabled)
          Text(request.url)
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
        .accessibilityLabel("Close request detail")
      }

      HStack(spacing: 12) {
        statusBadge
        Text(request.timingSummary)
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
    }
  }

  private func sectionBinding(for section: NetworkInspectorStore.RequestDetailSection) -> Binding<Bool> {
    store.bindingForSection(section, requestID: request.id, defaultExpanded: defaultExpansion(for: section))
  }

  private func defaultExpansion(for section: NetworkInspectorStore.RequestDetailSection) -> Bool {
    switch section {
    case .requestBody, .responseBody:
      false
    default:
      true
    }
  }

  private var statusBadge: some View {
    let label: String
    let color: Color

    if request.isStreamingResponse, request.streamClosed == nil {
      label = "Streaming"
      color = .blue
    } else {
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
    }

    return Text(label)
      .font(.caption)
      .foregroundStyle(color)
  }
}

private struct StreamEventsSection: View {
  let events: [NetworkInspectorRequestViewModel.StreamEvent]
  let closed: NetworkInspectorRequestViewModel.StreamClosed?
  @Binding var isExpanded: Bool

  init(
    events: [NetworkInspectorRequestViewModel.StreamEvent],
    closed: NetworkInspectorRequestViewModel.StreamClosed?,
    isExpanded: Binding<Bool>
  ) {
    self.events = events
    self.closed = closed
    _isExpanded = isExpanded
  }

  var body: some View {
    DisclosureGroup(isExpanded: $isExpanded) {
      contentView()
        .padding(.top, 6)
    } label: {
      Text("Server-Sent Events")
        .font(.headline)
    }
  }

  @ViewBuilder
  private func contentView() -> some View {
    if events.isEmpty {
      Text("Awaiting events…")
        .font(.subheadline)
        .foregroundStyle(.secondary)
    } else {
      LazyVStack(alignment: .leading, spacing: 8) {
        ForEach(events) { event in
          StreamEventCard(event: event)
        }
      }
    }

    if let closed {
      VStack(alignment: .leading, spacing: 4) {
        Text("Stream closed (\(closed.reason)) at \(closed.timestamp.formatted(date: .omitted, time: .standard))")
          .font(.callout)
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
        if let message = closed.message, !message.isEmpty {
          Text("Message: \(message)")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
        }
        Text("Total events: \(closed.totalEvents) • Total bytes: \(closed.totalBytes)")
          .font(.footnote)
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
      }
      .padding(.top, 4)
    }
  }
}

private struct StreamEventCard: View {
  let event: NetworkInspectorRequestViewModel.StreamEvent
  private let prettyPrintedData: String?
  private let isLikelyJSON: Bool
  @State private var usePrettyPrinted = false

  init(event: NetworkInspectorRequestViewModel.StreamEvent) {
    self.event = event
    if let data = event.data, !data.isEmpty {
      let trimmed = data.trimmingCharacters(in: .whitespacesAndNewlines)
      let pretty = NetworkInspectorRequestViewModel.BodyPayload.prettyPrintedJSON(from: data)
      prettyPrintedData = pretty
      isLikelyJSON = pretty != nil || trimmed.first == "{" || trimmed.first == "["
    } else {
      prettyPrintedData = nil
      isLikelyJSON = false
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 8) {
        Text("#\(event.sequence)")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
        Text(event.timestamp.formatted(date: .omitted, time: .standard))
          .font(.caption)
          .foregroundStyle(.secondary)
        if let name = event.eventName, !name.isEmpty {
          Text(name)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.primary)
        }
        Spacer()
        if prettyPrintedData != nil {
          Toggle("Pretty print", isOn: $usePrettyPrinted)
            .font(.caption)
            .toggleStyle(.checkbox)
        }
      }

      if let dataText = displayData {
        ExpandableText(text: dataText, font: .callout.monospaced())
      } else if isLikelyJSON, event.data != nil {
        Text("Unable to pretty print (invalid or truncated JSON)")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      if let comment = event.comment, !comment.isEmpty {
        Text("Comment: \(comment)")
          .font(.footnote)
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
      }
      if let lastId = event.lastEventId, !lastId.isEmpty {
        Text("Last-Event-ID: \(lastId)")
          .font(.footnote)
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
      }
      if let retry = event.retryMillis {
        Text("Retry: \(retry) ms")
          .font(.footnote)
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
      }
    }
    .padding(12)
    .background(
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .fill(Color.secondary.opacity(0.05))
    )
  }

  private var displayData: String? {
    guard let data = event.data, !data.isEmpty else { return nil }
    if usePrettyPrinted, let pretty = prettyPrintedData {
      return pretty
    }
    return data
  }
}

private struct ExpandableText: View {
  let text: String
  let font: Font
  let maximumHeight: CGFloat
  @State private var isExpanded = false
  @State private var fullHeight: CGFloat = .zero

  init(text: String, font: Font, maximumHeight: CGFloat = 100) {
    self.text = text
    self.font = font
    self.maximumHeight = maximumHeight
  }

  private var needsExpansion: Bool {
    fullHeight > maximumHeight + 1
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      textView()

      if needsExpansion {
        Button(isExpanded ? "Show Less" : "Show More") {
          withAnimation(.easeInOut(duration: 0.2)) {
            isExpanded.toggle()
          }
        }
        .font(.caption)
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
      }
    }
    .overlay(HeightReader(text: text, font: font))
    .onPreferenceChange(TextHeightPreferenceKey.self) { newValue in
      if abs(fullHeight - newValue) > 0.5 {
        fullHeight = newValue
      } else if fullHeight == 0 {
        fullHeight = newValue
      }
      if fullHeight <= maximumHeight + 1 {
        isExpanded = false
      }
    }
  }

  @ViewBuilder
  private func textView() -> some View {
    if !isExpanded, needsExpansion {
      Text(text)
        .font(font)
        .textSelection(.enabled)
        .frame(maxHeight: maximumHeight, alignment: .top)
        .clipped()
    } else {
      Text(text)
        .font(font)
        .textSelection(.enabled)
    }
  }

  private struct HeightReader: View {
    let text: String
    let font: Font

    var body: some View {
      Text(text)
        .font(font)
        .fixedSize(horizontal: false, vertical: true)
        .background(
          GeometryReader { proxy in
            Color.clear.preference(key: TextHeightPreferenceKey.self, value: proxy.size.height)
          }
        )
        .frame(width: 0, height: 0)
        .opacity(0)
        .allowsHitTesting(false)
    }
  }

  private struct TextHeightPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = .zero
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
      value = max(value, nextValue())
    }
  }
}
