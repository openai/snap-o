import SwiftUI

struct NetworkInspectorRequestDetailView: View {
  let request: NetworkInspectorRequestViewModel
  let onClose: () -> Void

  var body: some View {
    ScrollView(.vertical) {
      VStack(alignment: .leading, spacing: 16) {
        headerSummary

        NetworkInspectorHeadersSection(title: "Request Headers", headers: request.requestHeaders)
        if let requestBody = request.requestBody {
          NetworkInspectorBodySection(title: "Request Body", payload: requestBody)
        }
        NetworkInspectorHeadersSection(title: "Response Headers", headers: request.responseHeaders)

        if request.isStreamingResponse {
          StreamEventsSection(events: request.streamEvents, closed: request.streamClosed)
        }

        if let responseBody = request.responseBody {
          NetworkInspectorBodySection(title: "Response Body", payload: responseBody)
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

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Server-Sent Events")
        .font(.headline)

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
}

private struct StreamEventCard: View {
  let event: NetworkInspectorRequestViewModel.StreamEvent

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
      }

      VStack(alignment: .leading, spacing: 4) {
        if let data = event.data, !data.isEmpty {
          Text(data)
            .font(.system(.callout, design: .monospaced))
            .textSelection(.enabled)
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

      Text(event.raw)
        .font(.footnote.monospaced())
        .foregroundStyle(.tertiary)
        .textSelection(.enabled)
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
          RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(Color.secondary.opacity(0.08))
        )
    }
    .padding(12)
    .background(
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .fill(Color.secondary.opacity(0.05))
    )
  }
}
