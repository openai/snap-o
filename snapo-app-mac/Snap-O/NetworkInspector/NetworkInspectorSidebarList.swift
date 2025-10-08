import SwiftUI

struct NetworkInspectorSidebarList: View {
  @ObservedObject var requestStore: NetworkInspectorRequestStore
  let serverScopedItems: [NetworkInspectorListItemViewModel]
  let filteredItems: [NetworkInspectorListItemViewModel]
  let selectedServer: NetworkInspectorServerViewModel?
  @Binding var selectedItem: NetworkInspectorItemID?

  var body: some View {
    List(selection: $selectedItem) {
      if requestStore.items.isEmpty {
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
                NetworkInspectorCopyExporter.copyCurl(for: request)
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
        if let failure = webSocket.failed {
          Text(failure.message?.isEmpty == false ? failure.message ?? "Failed" : "Failed")
            .font(.caption)
            .foregroundStyle(Color.red)
        } else if webSocket.cancelled != nil {
          Text("Cancelled")
            .font(.caption)
            .foregroundStyle(Color.red)
        } else if let closed = webSocket.closed {
          Text("\(closed.code)")
            .font(.caption)
            .foregroundStyle(NetworkInspectorStatusPresentation.color(for: closed.code))
        } else if let closing = webSocket.closing {
          Text("\(closing.code)")
            .font(.caption)
            .foregroundStyle(NetworkInspectorStatusPresentation.color(for: closing.code))
        } else if let opened = webSocket.opened {
          Text("\(opened.code)")
            .font(.caption)
            .foregroundStyle(NetworkInspectorStatusPresentation.color(for: opened.code))
        } else {
          ProgressView()
            .controlSize(.small)
            .scaleEffect(0.75, anchor: .center)
            .padding(.vertical, 2)
        }
      }
    }
  }
}

private extension NetworkInspectorSidebarList {
  var statusPlaceholder: String {
    if selectedServer?.hasHello == true {
      return "No activity for this app yet"
    }
    return "Waiting for connection…"
  }
}
