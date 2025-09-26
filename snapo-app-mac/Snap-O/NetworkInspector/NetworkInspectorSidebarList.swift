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

              statusView(for: item.status)
            }
          }
          .contentShape(Rectangle())
          .tag(item.id)
        }
      }
    }
    .listStyle(.sidebar)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  @ViewBuilder
  private func statusView(for status: NetworkInspectorRequestViewModel.Status) -> some View {
    switch status {
    case .pending:
      ProgressView()
        .controlSize(.small)
        .scaleEffect(0.75, anchor: .center)
        .padding(.vertical, 2)
    case .success(let code):
      Text("\(code)")
        .font(.caption)
        .foregroundStyle(Color.green)
    case .failure(let message):
      Text(message?.isEmpty == false ? message ?? "Failed" : "Failed")
        .font(.caption)
        .foregroundStyle(Color.red)
    }
  }
}
