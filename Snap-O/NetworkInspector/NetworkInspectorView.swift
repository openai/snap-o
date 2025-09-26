import Foundation
import SwiftUI

struct NetworkInspectorView: View {
  @ObservedObject var store: NetworkInspectorStore
  @State private var selectedItem: NetworkInspectorItemID?
  @State private var requestSearchText = ""
  @State private var selectedServerID: NetworkInspectorServer.ID?
  @State private var splitViewVisibility: NavigationSplitViewVisibility = .all
  @State private var isServerPickerPresented = false
  @State private var activeDetail: NetworkInspectorDetailViewModel?

  private var serverScopedItems: [NetworkInspectorListItemViewModel] {
    store.items.filter { item in
      guard let selectedServerID else { return true }
      return item.serverID == selectedServerID
    }
  }

  private var filteredItems: [NetworkInspectorListItemViewModel] {
    let scoped = serverScopedItems
    guard !requestSearchText.isEmpty else {
      return scoped
    }

    return scoped.filter { item in
      item.url.localizedCaseInsensitiveContains(requestSearchText)
    }
  }

  private var selectedServer: NetworkInspectorServerViewModel? {
    guard let selectedServerID else { return store.servers.first }
    return store.servers.first { $0.id == selectedServerID } ?? store.servers.first
  }

  private var replacementServerCandidate: NetworkInspectorServerViewModel? {
    guard let current = selectedServer,
          current.isConnected == false else { return nil }

    return store.servers.first { candidate in
      candidate.isConnected &&
      candidate.id != current.id &&
      candidate.displayName == current.displayName &&
      candidate.deviceID == current.deviceID
    }
  }

  private func moveSelection(by offset: Int) {
    let items = filteredItems
    guard !items.isEmpty else { return }

    if let selection = selectedItem,
       let currentIndex = items.firstIndex(where: { $0.id == selection }) {
      let nextIndex = min(max(currentIndex + offset, 0), items.count - 1)
      selectedItem = items[nextIndex].id
    } else {
      selectedItem = offset >= 0 ? items.first?.id : items.last?.id
    }
  }

  var body: some View {
    NavigationSplitView(columnVisibility: $splitViewVisibility) {
      NetworkInspectorSidebar(
        store: store,
        selectedItem: $selectedItem,
        requestSearchText: $requestSearchText,
        selectedServerID: $selectedServerID,
        isServerPickerPresented: $isServerPickerPresented,
        serverScopedItems: serverScopedItems,
        filteredItems: filteredItems,
        selectedServer: selectedServer,
        replacementServerCandidate: replacementServerCandidate,
        moveSelection: moveSelection
      )
      .navigationTitle("Network Inspector")
    } detail: {
      if let detail = activeDetail {
        detailView(
          for: detail,
          onClose: {
          selectedItem = nil
          activeDetail = nil
          splitViewVisibility = .all
        }
                   )
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
    .navigationSplitViewStyle(.balanced)
    .navigationSplitViewColumnWidth(min: 280, ideal: 320, max: 360)
    .onChange(of: selectedServerID) { _, newValue in
      if let id = newValue {
        store.setRetainedServerIDs(Set([id]))
      } else {
        store.setRetainedServerIDs(Set<NetworkInspectorServer.ID>())
      }
    }
    .onChange(of: store.items.map(\.id)) { _, ids in
      reconcileSelection(allIDs: ids, filteredIDs: filteredItems.map(\.id))
      refreshActiveDetail()
    }
    .onChange(of: filteredItems.map(\.id)) { _, filteredIDs in
      reconcileSelection(allIDs: store.items.map(\.id), filteredIDs: filteredIDs)
      refreshActiveDetail()
    }
    .onChange(of: store.servers.map(\.id)) { _, ids in
      if ids.isEmpty {
        selectedServerID = nil
        isServerPickerPresented = false
      } else if let selection = selectedServerID,
                ids.contains(selection) {
        // keep existing selection
      } else {
        selectedServerID = ids.first
      }
    }
    .onAppear {
      if selectedServerID == nil {
        selectedServerID = store.servers.first?.id
      }

      if let id = selectedServerID {
        store.setRetainedServerIDs(Set([id]))
      } else {
        store.setRetainedServerIDs(Set<NetworkInspectorServer.ID>())
      }

      if selectedItem == nil {
        reconcileSelection(allIDs: store.items.map(\.id), filteredIDs: filteredItems.map(\.id))
      }

      refreshActiveDetail()
    }
    .onChange(of: selectedItem) { _, newValue in
      updateActiveDetail(for: newValue)
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

private extension NetworkInspectorView {
  @ViewBuilder
  func detailView(
    for detail: NetworkInspectorDetailViewModel,
    onClose: @escaping () -> Void
  ) -> some View {
    switch detail {
    case .request(let request):
      NetworkInspectorRequestDetailView(request: request, onClose: onClose)
        .id(request.id)
    case .webSocket(let webSocket):
      NetworkInspectorWebSocketDetailView(webSocket: webSocket, onClose: onClose)
        .id(webSocket.id)
    }
  }

  func reconcileSelection(
    allIDs: [NetworkInspectorItemID],
    filteredIDs: [NetworkInspectorItemID]
  ) {
    guard !allIDs.isEmpty else {
      selectedItem = nil
      return
    }

    if let selection = selectedItem {
      if filteredIDs.contains(selection) {
        return
      }

      if requestSearchText.isEmpty,
         selectedServerID == nil,
         allIDs.contains(selection) {
        return
      }
    }

    guard !filteredIDs.isEmpty else {
      selectedItem = requestSearchText.isEmpty && selectedServerID == nil ? allIDs.first : nil
      return
    }

    selectedItem = filteredIDs.first
  }

  func updateActiveDetail(for selection: NetworkInspectorItemID?) {
    guard let selection else {
      activeDetail = nil
      return
    }

    activeDetail = store.detail(for: selection)
  }

  func refreshActiveDetail() {
    updateActiveDetail(for: selectedItem)
  }
}
