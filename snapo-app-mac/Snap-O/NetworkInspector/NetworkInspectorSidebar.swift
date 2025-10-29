import SwiftUI

struct NetworkInspectorSidebar: View {
  @ObservedObject var store: NetworkInspectorStore
  @Binding var selectedItem: NetworkInspectorItemID?
  @Binding var requestSearchText: String
  @Binding var selectedServerID: SnapOLinkServerID?
  @Binding var isServerPickerPresented: Bool
  let serverScopedItems: [NetworkInspectorListItemViewModel]
  let filteredItems: [NetworkInspectorListItemViewModel]
  let selectedServer: NetworkInspectorServerViewModel?
  let replacementServerCandidate: NetworkInspectorServerViewModel?
  let moveSelection: (Int) -> Void

  var body: some View {
    VStack(spacing: 8) {
      NetworkInspectorSidebarServerControls(
        servers: store.servers,
        selectedServerID: $selectedServerID,
        isServerPickerPresented: $isServerPickerPresented,
        selectedServer: selectedServer,
        replacementServerCandidate: replacementServerCandidate
      )
      .padding(.horizontal, 12)

      HStack(spacing: 8) {
        NetworkInspectorSidebarSearchField(text: $requestSearchText, onMoveSelection: moveSelection)
          .frame(maxWidth: .infinity)

        Button {
          store.clearCompleted()
        } label: {
          Image(systemName: "trash")
            .font(.system(size: 13, weight: .semibold))
        }
        .buttonStyle(.borderless)
        .help("Clear completed requests")
        .disabled(!hasClearableItems)
      }
      .padding(.horizontal, 12)

      NetworkInspectorSidebarList(
        store: store,
        items: store.items,
        serverScopedItems: serverScopedItems,
        filteredItems: filteredItems,
        selectedServer: selectedServer,
        selectedItem: $selectedItem
      )
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
  }
}

private extension NetworkInspectorSidebar {
  var hasClearableItems: Bool {
    store.items.contains { !$0.isPending }
  }
}
