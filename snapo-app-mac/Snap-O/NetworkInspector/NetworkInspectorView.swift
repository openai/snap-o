import Foundation
import SwiftUI

struct NetworkInspectorView: View {
  @ObservedObject private var store: NetworkInspectorStore
  @State private var selectedItem: NetworkInspectorItemID?
  @State private var requestSearchText = ""
  @State private var selectedServerID: SnapOLinkServerID?
  @State private var splitViewVisibility: NavigationSplitViewVisibility = .all
  @State private var isServerPickerPresented = false

  init(store: NetworkInspectorStore) {
    _store = ObservedObject(wrappedValue: store)
  }

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
      .navigationTitle("Network Inspector (Alpha)")
    } detail: {
      detailContent
    }
    .navigationSplitViewStyle(.balanced)
    .navigationSplitViewColumnWidth(min: 280, ideal: 320, max: 360)
    .onChange(of: selectedServerID) { _, newValue in
      if let id = newValue {
        store.setRetainedServerIDs(Set([id]))
      } else {
        store.setRetainedServerIDs(Set<SnapOLinkServerID>())
      }
    }
    .onChange(of: store.items.map(\.id)) { _, ids in
      reconcileSelection(allIDs: ids, filteredIDs: filteredItems.map(\.id))
    }
    .onChange(of: filteredItems.map(\.id)) { _, filteredIDs in
      reconcileSelection(allIDs: store.items.map(\.id), filteredIDs: filteredIDs)
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
        store.setRetainedServerIDs(Set<SnapOLinkServerID>())
      }

      if selectedItem == nil {
        reconcileSelection(allIDs: store.items.map(\.id), filteredIDs: filteredItems.map(\.id))
      }
    }
  }

  private func statusLabel(for status: NetworkInspectorRequestStatus) -> String {
    switch status {
    case .pending:
      "Pending"
    case .success(let code):
      "\(code)"
    case .failure(let message):
      message?.isEmpty == false ? (message ?? "Failed") : "Failed"
    }
  }

  private func statusColor(for status: NetworkInspectorRequestStatus) -> Color {
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
    } else if store.servers.isEmpty {
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
    case .request(let requestID):
      NetworkInspectorRequestDetailView(store: store, requestID: requestID, onClose: onClose)
        .id(requestID)
    case .webSocket(let webSocketID):
      NetworkInspectorWebSocketDetailView(store: store, webSocketID: webSocketID, onClose: onClose)
        .id(webSocketID)
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
