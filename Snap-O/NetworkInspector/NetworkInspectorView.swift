import SwiftUI

struct NetworkInspectorView: View {
  @ObservedObject var store: NetworkInspectorStore

  var body: some View {
    NavigationView {
      List {
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
                HStack(alignment: .firstTextBaseline) {
                  Text(request.method)
                    .font(.system(.caption, design: .monospaced))
                    .bold()
                  Text(request.url)
                    .font(.subheadline)
                    .lineLimit(2)
                  Spacer()
                  Text(statusLabel(for: request.status))
                    .font(.caption)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(statusColor(for: request.status).opacity(0.15))
                    .foregroundStyle(statusColor(for: request.status))
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }

                Text(request.serverSummary)
                  .font(.caption)
                  .foregroundStyle(.secondary)

                Text(request.requestIdentifier)
                  .font(.caption2)
                  .foregroundStyle(Color.secondary.opacity(0.7))

                Text(request.timingSummary)
                  .font(.caption2)
                  .foregroundStyle(Color.secondary.opacity(0.7))
              }
              .padding(.vertical, 6)
            }
          }
        }
      }
      .navigationTitle("Network Inspector")
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
