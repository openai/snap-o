import SwiftUI

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
