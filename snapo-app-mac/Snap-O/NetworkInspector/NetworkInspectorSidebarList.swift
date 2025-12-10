import SwiftUI

struct NetworkInspectorSidebarList: View {
  let store: NetworkInspectorStore
  let items: [NetworkInspectorListItemViewModel]
  let serverScopedItems: [NetworkInspectorListItemViewModel]
  let filteredItems: [NetworkInspectorListItemViewModel]
  let selectedServer: NetworkInspectorServerViewModel?
  @Binding var selectedItem: NetworkInspectorItemID?
  @State private var isScrolledToTop = true
  @State private var isScrolledToBottom = true

  var body: some View {
    ScrollViewReader { proxy in
      List(selection: $selectedItem) {
        if let placeholder = placeholderText {
          placeholderRow(placeholder)
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
                  if let model = store.requestViewModel(for: request.id) {
                    NetworkInspectorCopyExporter.copyCurl(for: model)
                  }
                }
              }
            }
            .tag(item.id)
            .background(alignment: .topLeading) {
              edgeVisibilityMarkers(for: item.id)
            }
          }
        }
      }
      .listStyle(.sidebar)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .onChange(of: filteredItems.map(\.id)) { previous, current in
        handleListChange(previous: previous, current: current, proxy: proxy)
      }
    }
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
        switch webSocket.status {
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
          let label = message?.isEmpty == false ? message ?? "Failed" : "Failed"
          Text(label)
            .font(.caption)
            .foregroundStyle(Color.red)
        }
      }
    }
  }
}

private extension NetworkInspectorSidebarList {
  var firstItemID: NetworkInspectorItemID? {
    filteredItems.first?.id
  }

  var lastItemID: NetworkInspectorItemID? {
    filteredItems.last?.id
  }

  var isShowingItems: Bool {
    !items.isEmpty && !serverScopedItems.isEmpty && !filteredItems.isEmpty
  }

  var placeholderText: String? {
    if items.isEmpty { return "No activity yet" }
    if serverScopedItems.isEmpty { return statusPlaceholder }
    if filteredItems.isEmpty { return "No matches" }
    return nil
  }

  var statusPlaceholder: String {
    if selectedServer?.hasHello == true {
      return "No activity for this app yet"
    }
    return "Waiting for connection…"
  }

  @ViewBuilder
  func placeholderRow(_ text: String) -> some View {
    Text(text)
      .foregroundStyle(.secondary)
      .onAppear(perform: resetEdgePositions)
  }

  @ViewBuilder
  func edgeVisibilityMarkers(for id: NetworkInspectorItemID) -> some View {
    if id == firstItemID {
      EdgeVisibilityDetector { isScrolledToTop = $0 }
    }

    if id == lastItemID {
      EdgeVisibilityDetector { isScrolledToBottom = $0 }
    }
  }

  func handleListChange(
    previous: [NetworkInspectorItemID],
    current: [NetworkInspectorItemID],
    proxy: ScrollViewProxy
  ) {
    guard isShowingItems, !current.isEmpty,
          !Set(current).subtracting(previous).isEmpty
    else { return }

    let anchor: UnitPoint
    let targetID: NetworkInspectorItemID?

    switch store.listSortOrder {
    case .newestFirst where isScrolledToTop:
      anchor = .top
      targetID = current.first
    case .oldestFirst where isScrolledToBottom:
      anchor = .bottom
      targetID = current.last
    default:
      return
    }

    if let targetID {
      proxy.scrollTo(targetID, anchor: anchor)
    }
  }

  func resetEdgePositions() {
    isScrolledToTop = true
    isScrolledToBottom = true
  }
}

private struct EdgeVisibilityDetector: View {
  var onVisibilityChange: (Bool) -> Void

  var body: some View {
    Color.clear
      .frame(width: 1, height: 1)
      .onAppear { onVisibilityChange(true) }
      .onDisappear { onVisibilityChange(false) }
  }
}
