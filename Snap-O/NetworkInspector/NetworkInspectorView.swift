import AppKit
import Foundation
import SwiftUI

struct NetworkInspectorView: View {
  @ObservedObject var store: NetworkInspectorStore
  @State private var selectedItem: NetworkInspectorItemID?
  @State private var requestSearchText = ""
  @State private var selectedServerID: NetworkInspectorServer.ID?
  @State private var splitViewVisibility: NavigationSplitViewVisibility = .all
  @State private var isServerPickerPresented = false

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
    let displayedItems = filteredItems

    NavigationSplitView(columnVisibility: $splitViewVisibility) {
      VStack(spacing: 8) {
        serverPicker
          .padding(.horizontal, 12)

        NetworkInspectorSearchField(text: $requestSearchText) { direction in
          moveSelection(by: direction)
        }
        .padding(.horizontal, 12)

        List(selection: $selectedItem) {
          if store.items.isEmpty {
            Text("No activity yet")
              .foregroundStyle(.secondary)
          } else if serverScopedItems.isEmpty {
            Text("No activity for this app yet")
              .foregroundStyle(.secondary)
          } else if displayedItems.isEmpty {
            Text("No matches")
              .foregroundStyle(.secondary)
          } else {
            ForEach(displayedItems) { item in
              VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
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
        .listStyle(.sidebar)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
      .navigationTitle("Network Inspector")
    } detail: {
      if let selection = selectedItem,
         let detail = store.detail(for: selection) {
        detailView(
          for: detail,
          onClose: {
          selectedItem = nil
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
        store.setRetainedServerIDs(Set<NetworkInspectorServer.ID>())
      }

      if selectedItem == nil {
        reconcileSelection(allIDs: store.items.map(\.id), filteredIDs: filteredItems.map(\.id))
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

  private var serverPicker: some View {
    Group {
      if store.servers.isEmpty {
        HStack {
          Text("No Apps Found")
            .font(.callout)
            .foregroundStyle(.secondary)
          Spacer()
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
          RoundedRectangle(cornerRadius: 8)
            .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
        )
      } else {
        Button {
          isServerPickerPresented.toggle()
        } label: {
          HStack(spacing: 12) {
            if let server = selectedServer {
              serverRowContent(for: server)
            } else {
              placeholderRowContent(title: "Select an App", subtitle: "")
            }

            Spacer()

            Image(systemName: "chevron.down")
              .font(.caption.weight(.semibold))
              .foregroundStyle(.secondary)
          }
          .padding(.vertical, 10)
          .padding(.horizontal, 12)
          .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
          .background(
            RoundedRectangle(cornerRadius: 8)
              .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
          )
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isServerPickerPresented, arrowEdge: .bottom) {
          VStack(alignment: .leading, spacing: 0) {
            serversPopover
          }
          .padding(8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
  }

  @ViewBuilder
  private func serverRowContent(for server: NetworkInspectorServerViewModel) -> some View {
    serverRow(title: server.displayName, subtitle: server.deviceDisplayTitle, isConnected: server.isConnected)
  }

  private func placeholderRowContent(title: String, subtitle: String) -> some View {
    serverRow(title: title, subtitle: subtitle, isConnected: true)
  }

  private func serverRow(title: String, subtitle: String, isConnected: Bool) -> some View {
    HStack(spacing: 12) {
      appIconView(isConnected: isConnected)

      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .font(.headline)
          .foregroundStyle(.primary)
          .lineLimit(1)
          .fixedSize(horizontal: false, vertical: true)
        if !subtitle.isEmpty {
          Text(subtitle)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
    }
    .opacity(isConnected ? 1 : 0.75)
  }

  private func appIconView(isConnected: Bool) -> some View {
    RoundedRectangle(cornerRadius: 8)
      .fill(isConnected ? Color.secondary.opacity(0.12) : Color.secondary.opacity(0.05))
      .overlay(
        Image(systemName: "app.fill")
          .font(.subheadline)
          .foregroundStyle(isConnected ? Color.secondary : Color.secondary.opacity(0.35))
          .saturation(isConnected ? 1 : 0)
      )
      .overlay(alignment: .bottomTrailing) {
        if !isConnected {
          Image(systemName: "link.slash")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(Color.secondary)
            .padding(4)
            .background(Circle().fill(Color.secondary.opacity(0.2)))
            .offset(x: 4, y: 4)
        }
      }
      .saturation(isConnected ? 1 : 0)
      .opacity(isConnected ? 1 : 0.6)
      .frame(width: 32, height: 32)
  }

  private var serversPopover: some View {
    VStack(alignment: .leading, spacing: 0) {
      ForEach(store.servers) { server in
        Button {
          selectedServerID = server.id
          isServerPickerPresented = false
        } label: {
          serverRowContent(for: server)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .background(
              (selectedServerID == server.id ? Color.accentColor.opacity(0.12) : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
      }
    }
    .padding(.vertical, 8)
    .frame(minWidth: 280)
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
    case .webSocket(let webSocket):
      NetworkInspectorWebSocketDetailView(webSocket: webSocket, onClose: onClose)
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

private struct NetworkInspectorSearchField: NSViewRepresentable {
  @Binding var text: String
  var onMoveSelection: (Int) -> Void

  func makeCoordinator() -> Coordinator {
    Coordinator(text: $text, onMoveSelection: onMoveSelection)
  }

  func makeNSView(context: Context) -> ArrowHandlingSearchField {
    let searchField = ArrowHandlingSearchField()
    searchField.placeholderString = "Filter by URL"
    searchField.focusRingType = .none
    searchField.delegate = context.coordinator
    searchField.stringValue = text
    searchField.moveSelection = { direction in
      context.coordinator.moveSelection(by: direction)
    }
    return searchField
  }

  func updateNSView(_ nsView: ArrowHandlingSearchField, context: Context) {
    if nsView.stringValue != text {
      nsView.stringValue = text
    }
  }

  final class Coordinator: NSObject, NSSearchFieldDelegate {
    @Binding var text: String
    private let onMoveSelection: (Int) -> Void

    init(text: Binding<String>, onMoveSelection: @escaping (Int) -> Void) {
      _text = text
      self.onMoveSelection = onMoveSelection
    }

    func controlTextDidChange(_ notification: Notification) {
      guard let field = notification.object as? NSSearchField else { return }
      text = field.stringValue
    }

    func moveSelection(by offset: Int) {
      onMoveSelection(offset)
    }
  }

  final class ArrowHandlingSearchField: NSSearchField {
    var moveSelection: ((Int) -> Void)?

    override func keyDown(with event: NSEvent) {
      let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
      if modifiers.isDisjoint(with: [.command, .option, .control]) {
        switch event.keyCode {
        case 125: // down arrow
          moveSelection?(1)
          return
        case 126: // up arrow
          moveSelection?(-1)
          return
        default:
          break
        }
      }

      super.keyDown(with: event)
    }
  }
}
