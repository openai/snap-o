import SwiftUI
import Foundation

struct NetworkInspectorRequestDetailView: View {
  @ObservedObject var store: NetworkInspectorStore
  let request: NetworkInspectorRequestViewModel
  let onClose: () -> Void

  var body: some View {
    ScrollView(.vertical) {
      VStack(alignment: .leading, spacing: 16) {
        headerSummary

        if !request.requestHeaders.isEmpty {
          NetworkInspectorHeadersSection(
            title: "Request Headers",
            headers: request.requestHeaders,
            isExpanded: sectionBinding(for: .requestHeaders)
          )
        }

        if let requestBody = request.requestBody {
          NetworkInspectorBodySection(
            title: "Request Body",
            payload: requestBody,
            isExpanded: sectionBinding(for: .requestBody)
          )
        }

        if !request.responseHeaders.isEmpty {
          NetworkInspectorHeadersSection(
            title: "Response Headers",
            headers: request.responseHeaders,
            isExpanded: sectionBinding(for: .responseHeaders)
          )
        }

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
    store.bindingForSection(
      section,
      requestID: request.id,
      defaultExpanded: defaultExpansion(for: section)
    )
  }

  private func defaultExpansion(for section: NetworkInspectorStore.RequestDetailSection) -> Bool {
    switch section {
    case .requestBody, .responseBody:
      return false
    default:
      return true
    }
  }

  private var statusBadge: some View {
    let label: String
    let color: Color

    if request.isStreamingResponse && request.streamClosed == nil {
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
      VStack(alignment: .leading, spacing: 10) {
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
      .padding(.top, 6)
    } label: {
      Text("Server-Sent Events")
        .font(.headline)
    }
  }
}

private struct StreamEventCard: View {
  let event: NetworkInspectorRequestViewModel.StreamEvent
  private let prettyPrintedData: String?
  private let isLikelyJSON: Bool
  @State private var usePrettyPrinted: Bool

  init(event: NetworkInspectorRequestViewModel.StreamEvent) {
    self.event = event
    _usePrettyPrinted = State(initialValue: false)
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
    InspectorCard {
      header

      if let dataText = event.data, !dataText.isEmpty {
        InspectorPayloadView(
          rawText: dataText,
          prettyText: prettyPrintedData,
          isLikelyJSON: isLikelyJSON,
          usePrettyPrinted: $usePrettyPrinted,
          showsToggle: false
        )
      } else if isLikelyJSON {
        Text("Unable to pretty print (invalid or truncated JSON)")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      metadata
    }
  }

  private var header: some View {
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
  }

  @ViewBuilder
  private var metadata: some View {
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
}
