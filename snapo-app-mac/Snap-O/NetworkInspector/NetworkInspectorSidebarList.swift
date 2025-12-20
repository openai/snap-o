import SwiftUI

struct NetworkInspectorSidebarList: View {
  let store: NetworkInspectorStore
  let items: [NetworkInspectorListItemViewModel]
  let serverScopedItems: [NetworkInspectorListItemViewModel]
  let filteredItems: [NetworkInspectorListItemViewModel]
  let selectedServer: NetworkInspectorServerViewModel?
  @Binding var selectedItem: NetworkInspectorItemID?

  var body: some View {
    List(selection: $selectedItem) {
      if items.isEmpty {
        Text("No activity yet")
          .foregroundStyle(.secondary)
      } else if serverScopedItems.isEmpty {
        Text(statusPlaceholder)
          .foregroundStyle(.secondary)
      } else if filteredItems.isEmpty {
        Text("No matches")
          .foregroundStyle(.secondary)
      } else {
        ForEach(filteredItems) { item in
          VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 8) {
              VStack(alignment: .leading) {
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

              Text(item.method)
                .font(.system(.caption, design: .monospaced))
                .bold()
                .foregroundStyle(.secondary)

              statusView(for: item)
            }
          }
          .contentShape(Rectangle())
          .contextMenu {
            if case .request(let request) = item.kind {
              Button("Copy URL") {
                NetworkInspectorCopyExporter.copyURL(request.url)
              }

              Button("Copy as cURL") {
                if let model = store.requestViewModel(for: request.id) {
                  NetworkInspectorCopyExporter.copyCurl(for: model)
                }
              }
            }
          }
          .tag(item.id)
        }
      }
    }
    .listStyle(.sidebar)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  @ViewBuilder
  private func statusView(for item: NetworkInspectorListItemViewModel) -> some View {
    if item.showsActiveIndicator {
      Circle()
        .fill(Color.green)
        .frame(width: 8, height: 8)
        .padding(.vertical, 2)
    } else {
      switch item.kind {
      case .request(let request):
        switch request.status {
        case .pending:
          ProgressView()
            .controlSize(.small)
            .scaleEffect(0.75, anchor: .center)
            .padding(.vertical, 2)
        case .success(let code):
          Text("\(code)")
            .font(.caption)
            .foregroundStyle(NetworkInspectorStatusPresentation.color(for: code))
        case .failure(let message):
          Text(message?.isEmpty == false ? message ?? "Failed" : "Failed")
            .font(.caption)
            .foregroundStyle(Color.red)
        }
      case .webSocket(let webSocket):
        switch webSocket.status {
        case .pending:
          ProgressView()
            .controlSize(.small)
            .scaleEffect(0.75, anchor: .center)
            .padding(.vertical, 2)
        case .success(let code):
          Text("\(code)")
            .font(.caption)
            .foregroundStyle(NetworkInspectorStatusPresentation.color(for: code))
        case .failure(let message):
          let label = message?.isEmpty == false ? message ?? "Failed" : "Failed"
          Text(label)
            .font(.caption)
            .foregroundStyle(Color.red)
        }
      }
    }
  }
}

private extension NetworkInspectorSidebarList {
  var statusPlaceholder: String {
    guard let server = selectedServer else {
      return "Waiting for connection…"
    }

    if server.hasHello {
      return "No activity for this app yet"
    }

    return "Waiting for connection…"
  }
}
