import AppKit
import Foundation
import SwiftUI

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
      "Pending"
    case .success(let code):
      "\(code)"
    case .failure(let message):
      message?.isEmpty == false ? message! : "Failed"
    }
  }

  private func statusColor(for status: NetworkInspectorRequestViewModel.Status) -> Color {
    switch status {
    case .pending:
      .secondary
    case .success:
      .green
    case .failure:
      .red
    }
  }
}
