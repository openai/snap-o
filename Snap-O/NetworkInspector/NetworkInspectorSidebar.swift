import SwiftUI

struct NetworkInspectorSidebar: View {
  @ObservedObject var store: NetworkInspectorStore
  @Binding var selectedItem: NetworkInspectorItemID?
  @Binding var requestSearchText: String
  @Binding var selectedServerID: NetworkInspectorServer.ID?
  @Binding var isServerPickerPresented: Bool
  let serverScopedItems: [NetworkInspectorListItemViewModel]
  let filteredItems: [NetworkInspectorListItemViewModel]
  let selectedServer: NetworkInspectorServerViewModel?
  let replacementServerCandidate: NetworkInspectorServerViewModel?
  let moveSelection: (Int) -> Void

  var body: some View {
    VStack(spacing: 8) {
      NetworkInspectorSidebarServerControls(
        store: store,
        selectedServerID: $selectedServerID,
        isServerPickerPresented: $isServerPickerPresented,
        selectedServer: selectedServer,
        replacementServerCandidate: replacementServerCandidate
      )
      .padding(.horizontal, 12)

      NetworkInspectorSidebarSearchField(text: $requestSearchText, onMoveSelection: moveSelection)
        .padding(.horizontal, 12)

      NetworkInspectorSidebarList(
        store: store,
        serverScopedItems: serverScopedItems,
        filteredItems: filteredItems,
        selectedItem: $selectedItem
      )
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
  }
}
