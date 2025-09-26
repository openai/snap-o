import SwiftUI

struct NetworkInspectorSidebarList: View {
  @ObservedObject var store: NetworkInspectorStore
  let serverScopedItems: [NetworkInspectorListItemViewModel]
  let filteredItems: [NetworkInspectorListItemViewModel]
  @Binding var selectedItem: NetworkInspectorItemID?

  var body: some View {
    List(selection: $selectedItem) {
      if store.items.isEmpty {
        Text("No activity yet")
          .foregroundStyle(.secondary)
      } else if serverScopedItems.isEmpty {
        Text("No activity for this app yet")
          .foregroundStyle(.secondary)
      } else if filteredItems.isEmpty {
        Text("No matches")
          .foregroundStyle(.secondary)
      } else {
        ForEach(filteredItems) { item in
          VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
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

              Text(item.method)
                .font(.system(.caption, design: .monospaced))
                .bold()
                .foregroundStyle(.secondary)

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
    .listStyle(.sidebar)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private func statusLabel(for status: NetworkInspectorRequestViewModel.Status) -> String {
    switch status {
    case .pending:
      return "Pending"
    case .success(let code):
      return "\(code)"
    case .failure(let message):
      return message?.isEmpty == false ? message! : "Failed"
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
