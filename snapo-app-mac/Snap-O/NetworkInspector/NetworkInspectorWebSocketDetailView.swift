import Combine
import Foundation
import SwiftUI

struct NetworkInspectorWebSocketDetailView: View {
  @StateObject private var viewModel: NetworkInspectorWebSocketDetailViewModel
  let onClose: () -> Void
  @State private var requestHeadersExpanded = false

  init(store: NetworkInspectorStore, webSocketID: NetworkInspectorWebSocketID, onClose: @escaping () -> Void) {
    _viewModel = StateObject(wrappedValue: NetworkInspectorWebSocketDetailViewModel(store: store, webSocketID: webSocketID))
    self.onClose = onClose
  }

  var body: some View {
    Group {
      if let webSocket = viewModel.webSocket {
        ScrollView(.vertical) {
          VStack(alignment: .leading, spacing: 16) {
            headerSummary(webSocket)

            NetworkInspectorHeadersSection(
              title: "Request Headers",
              headers: webSocket.requestHeaders,
              isExpanded: $requestHeadersExpanded
            )
            NetworkInspectorHeadersSection(title: "Response Headers", headers: webSocket.responseHeaders)

            messagesSection(webSocket)
          }
          .padding(24)
        }
      } else {
        VStack(spacing: 12) {
          ProgressView()
          Text("Loading web socket details…")
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
  }

  private func headerSummary(_ webSocket: NetworkInspectorWebSocketViewModel) -> some View {
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
        statusBadge(webSocket)
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
        let acceptance = closeRequested.accepted ? "accepted" : "not accepted"
        let summaryParts = [
          "Close requested: \(closeRequested.code)",
          closeRequested.initiated.capitalized,
          acceptance
        ]
        Text(summaryParts.joined(separator: " • "))
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

  private func statusBadge(_ webSocket: NetworkInspectorWebSocketViewModel) -> some View {
    let label: String
    let color: Color

    if let closed = webSocket.closed {
      label = NetworkInspectorStatusPresentation.displayName(for: closed.code)
      color = NetworkInspectorStatusPresentation.color(for: closed.code)
    } else if let closing = webSocket.closing {
      label = NetworkInspectorStatusPresentation.displayName(for: closing.code)
      color = NetworkInspectorStatusPresentation.color(for: closing.code)
    } else if let opened = webSocket.opened {
      label = NetworkInspectorStatusPresentation.displayName(for: opened.code)
      color = NetworkInspectorStatusPresentation.color(for: opened.code)
    } else {
      switch webSocket.status {
      case .pending:
        label = "Pending"
        color = .secondary
      case .success(let code):
        label = NetworkInspectorStatusPresentation.displayName(for: code)
        color = NetworkInspectorStatusPresentation.color(for: code)
      case .failure(let message):
        if let message, !message.isEmpty {
          label = message
        } else {
          label = "Failed"
        }
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

  private func messagesSection(_ webSocket: NetworkInspectorWebSocketViewModel) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Messages")
        .font(.headline)

      if webSocket.messages.isEmpty {
        Text("No messages yet")
          .font(.subheadline)
          .foregroundStyle(.secondary)
      } else {
        LazyVStack(alignment: .leading, spacing: 8) {
          ForEach(webSocket.messages) { message in
            MessageCardView(message: message)
          }
        }
      }
    }
  }
}

private struct MessageCardView: View {
  let message: NetworkInspectorWebSocketViewModel.Message

  private let prettyPrintedPreview: String?
  private let isLikelyJSON: Bool
  private let directionSymbolName: String
  private let directionColor: Color
  @State private var usePrettyPrinted: Bool

  init(message: NetworkInspectorWebSocketViewModel.Message) {
    self.message = message

    if let preview = message.preview, !preview.isEmpty {
      let trimmed = preview.trimmingCharacters(in: .whitespacesAndNewlines)
      let pretty = MessageCardView.prettyPrintedJSON(from: preview)
      prettyPrintedPreview = pretty
      let encodingHint = message.opcode.lowercased().contains("json")
      isLikelyJSON = encodingHint || trimmed.first == "{" || trimmed.first == "["
    } else {
      prettyPrintedPreview = nil
      isLikelyJSON = false
    }

    _usePrettyPrinted = State(initialValue: false)

    if message.direction == .outgoing {
      directionSymbolName = "paperplane"
      directionColor = .blue
    } else {
      directionSymbolName = "tray"
      directionColor = .green
    }
  }

  var body: some View {
    InspectorCard {
      header

      if let preview = message.preview, !preview.isEmpty {
        InspectorPayloadView(
          rawText: preview,
          prettyText: prettyPrintedPreview,
          isLikelyJSON: isLikelyJSON,
          usePrettyPrinted: $usePrettyPrinted,
          showsToggle: false,
          isExpandable: !usePrettyPrinted
        )
      } else if isLikelyJSON {
        Text("Unable to pretty print (invalid or truncated JSON)")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }

  private var header: some View {
    HStack(spacing: 4) {
      Image(systemName: directionSymbolName)
        .font(.caption.weight(.semibold))
        .symbolRenderingMode(.hierarchical)
        .foregroundStyle(directionColor)
      if let size = message.payloadSize {
        Text("\(formatBytes(size))")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      if prettyPrintedPreview != nil {
        Toggle("Pretty print", isOn: $usePrettyPrinted)
          .font(.caption)
          .toggleStyle(.checkbox)
      }

      Spacer()

      if let enqueued = message.enqueued {
        Text(enqueued ? "Enqueued" : "Immediate")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Text(message.timestamp.inspectorTimeString)
        .font(.caption)
        .foregroundStyle(.secondary)
      Text(message.opcode)
        .font(.caption.monospaced())
        .foregroundStyle(.secondary)
    }
  }

  private static func prettyPrintedJSON(from text: String) -> String? {
    guard let data = text.data(using: .utf8) else { return nil }
    do {
      let object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
      let prettyData = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted])
      return String(data: prettyData, encoding: .utf8)
    } catch {
      return nil
    }
  }
}

@MainActor
final class NetworkInspectorWebSocketDetailViewModel: ObservableObject {
  @Published private(set) var webSocket: NetworkInspectorWebSocketViewModel?

  private let store: NetworkInspectorStore
  private let webSocketID: NetworkInspectorWebSocketID
  private var cancellable: AnyCancellable?

  init(store: NetworkInspectorStore, webSocketID: NetworkInspectorWebSocketID) {
    self.store = store
    self.webSocketID = webSocketID
    webSocket = store.webSocketViewModel(for: webSocketID)

    cancellable = store.$items
      .receive(on: DispatchQueue.main)
      .sink { [weak self] _ in
        guard let self else { return }
        self.webSocket = store.webSocketViewModel(for: self.webSocketID)
      }
  }
}

private func formatBytes(_ byteCount: Int64) -> String {
  let formatter = ByteCountFormatter()
  formatter.countStyle = .binary
  return formatter.string(fromByteCount: byteCount)
}
