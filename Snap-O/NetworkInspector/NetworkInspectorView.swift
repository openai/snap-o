import AppKit
import Foundation
import SwiftUI

struct NetworkInspectorView: View {
  @ObservedObject var store: NetworkInspectorStore
  @State private var selectedItem: NetworkInspectorItemID?
  @State private var requestSearchText = ""
  @State private var splitViewVisibility: NavigationSplitViewVisibility = .all

  private var filteredItems: [NetworkInspectorListItemViewModel] {
    guard !requestSearchText.isEmpty else {
      return store.items
    }

    return store.items.filter { item in
      item.url.localizedCaseInsensitiveContains(requestSearchText)
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
    let displayedItems = filteredItems

    NavigationSplitView(columnVisibility: $splitViewVisibility) {
      VStack(spacing: 8) {
        NetworkInspectorSearchField(text: $requestSearchText) { direction in
          moveSelection(by: direction)
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)

        List(selection: $selectedItem) {
          Section("Servers") {
            if store.servers.isEmpty {
              Text("No active servers")
                .foregroundStyle(.secondary)
            } else {
              ForEach(store.servers) { server in
                VStack(alignment: .leading, spacing: 2) {
                  Text(server.displayName)
                    .font(.headline)
                  if let hello = server.helloSummary {
                    Text(hello)
                      .font(.caption)
                      .foregroundStyle(.secondary)
                  }
                }
              }
            }
          }

          Section("Requests & WebSockets") {
            if store.items.isEmpty {
              Text("No activity yet")
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
        }
        .listStyle(.sidebar)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
      .navigationTitle("Network Inspector")
    } detail: {
      if let selection = selectedItem,
         let detail = store.detail(for: selection) {
        ZStack(alignment: .topTrailing) {
          detailView(for: detail)

          Button {
            withAnimation {
              splitViewVisibility = .all
              selectedItem = nil
            }
          } label: {
            Image(systemName: "xmark.circle.fill")
              .font(.title3)
              .symbolRenderingMode(.hierarchical)
          }
          .buttonStyle(.plain)
          .padding(16)
          .accessibilityLabel("Close detail")
        }
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
    .onChange(of: store.items.map(\.id)) { _, ids in
      reconcileSelection(allIDs: ids, filteredIDs: filteredItems.map(\.id))
    }
    .onChange(of: filteredItems.map(\.id)) { _, filteredIDs in
      reconcileSelection(allIDs: store.items.map(\.id), filteredIDs: filteredIDs)
    }
    .onAppear {
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
}

extension NetworkInspectorView {
  @ViewBuilder
  private func detailView(for detail: NetworkInspectorDetailViewModel) -> some View {
    switch detail {
    case .request(let request):
      NetworkInspectorRequestDetailView(request: request)
    case .webSocket(let webSocket):
      NetworkInspectorWebSocketDetailView(webSocket: webSocket)
    }
  }
}

private extension NetworkInspectorView {
  func reconcileSelection(allIDs: [NetworkInspectorItemID],
                          filteredIDs: [NetworkInspectorItemID]) {
    guard !allIDs.isEmpty else {
      selectedItem = nil
      return
    }

    if requestSearchText.isEmpty {
      if let selection = selectedItem,
         allIDs.contains(selection) {
        return
      }

      selectedItem = filteredIDs.first ?? allIDs.first
    } else {
      guard !filteredIDs.isEmpty else {
        selectedItem = nil
        return
      }

      if let selection = selectedItem,
         filteredIDs.contains(selection) {
        return
      }

      selectedItem = filteredIDs.first
    }
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
