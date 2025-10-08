import Foundation
import SwiftUI

struct NetworkInspectorView: View {
  @ObservedObject private var store: NetworkInspectorStore
  @StateObject private var requestStore: NetworkInspectorRequestStore
  @State private var selectedItem: NetworkInspectorItemID?
  @State private var requestSearchText = ""
  @State private var selectedServerID: SnapOLinkServerID?
  @State private var splitViewVisibility: NavigationSplitViewVisibility = .all
  @State private var isServerPickerPresented = false

  init(store: NetworkInspectorStore) {
    _store = ObservedObject(wrappedValue: store)
    _requestStore = StateObject(wrappedValue: NetworkInspectorRequestStore(store: store))
  }

  private var serverScopedItems: [NetworkInspectorListItemViewModel] {
    requestStore.items.filter { item in
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
    guard let selectedServerID else { return requestStore.servers.first }
    return requestStore.servers.first { $0.id == selectedServerID } ?? requestStore.servers.first
  }

  private var replacementServerCandidate: NetworkInspectorServerViewModel? {
    guard let current = selectedServer,
          current.isConnected == false else { return nil }

    return requestStore.servers.first { candidate in
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
        requestStore: requestStore,
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
      .navigationTitle("Network Inspector (Alpha)")
    } detail: {
      detailContent
    }
    .navigationSplitViewStyle(.balanced)
    .navigationSplitViewColumnWidth(min: 280, ideal: 320, max: 360)
    .onChange(of: selectedServerID) { _, newValue in
      if let id = newValue {
        requestStore.setRetainedServerIDs(Set([id]))
      } else {
        requestStore.setRetainedServerIDs(Set<SnapOLinkServerID>())
      }
    }
    .onChange(of: requestStore.items.map(\.id)) { _, ids in
      reconcileSelection(allIDs: ids, filteredIDs: filteredItems.map(\.id))
    }
    .onChange(of: filteredItems.map(\.id)) { _, filteredIDs in
      reconcileSelection(allIDs: requestStore.items.map(\.id), filteredIDs: filteredIDs)
    }
    .onChange(of: requestStore.servers.map(\.id)) { _, ids in
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
        selectedServerID = requestStore.servers.first?.id
      }

      if let id = selectedServerID {
        requestStore.setRetainedServerIDs(Set([id]))
      } else {
        requestStore.setRetainedServerIDs(Set<SnapOLinkServerID>())
      }

      if selectedItem == nil {
        reconcileSelection(allIDs: requestStore.items.map(\.id), filteredIDs: filteredItems.map(\.id))
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
      message?.isEmpty == false ? (message ?? "Failed") : "Failed"
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
  @ViewBuilder var detailContent: some View {
    if let selection = selectedItem,
       let detail = store.detail(for: selection) {
      detailView(for: detail) {
        selectedItem = nil
        splitViewVisibility = .all
      }
    } else if requestStore.servers.isEmpty {
      emptyStateView()
    } else {
      placeholderSelectionView
    }
  }

  @ViewBuilder
  private func emptyStateView() -> some View {
    VStack(spacing: 16) {
      Image(systemName: "antenna.radiowaves.left.and.right")
        .font(.system(size: 48, weight: .regular))
        .foregroundStyle(.secondary)

      VStack(spacing: 8) {
        Text("No compatible apps detected")
          .font(.title3.weight(.semibold))

        Text("Apps must include the `com.openai.snapo` dependencies to appear here.")
          .font(.body)
          .multilineTextAlignment(.center)
          .foregroundStyle(.secondary)
      }

      if let documentationURL = URL(string: "https://openai.github.io/snap-o/link") {
        Link(destination: documentationURL) {
          Text("Learn about Snap-O Link")
        }
        .buttonStyle(.link)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  @ViewBuilder private var placeholderSelectionView: some View {
    VStack(spacing: 12) {
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

private extension NetworkInspectorView {
  @ViewBuilder
  func detailView(
    for detail: NetworkInspectorDetailViewModel,
    onClose: @escaping () -> Void
  ) -> some View {
    switch detail {
    case .request(let request):
      NetworkInspectorRequestDetailView(store: store, request: request, onClose: onClose)
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
}
