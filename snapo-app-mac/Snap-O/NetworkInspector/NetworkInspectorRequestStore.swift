import Combine
import Foundation

@MainActor
final class NetworkInspectorRequestStore: ObservableObject {
  @Published private(set) var servers: [NetworkInspectorServerViewModel] = []
  @Published private(set) var items: [NetworkInspectorListItemViewModel] = []

  private var cancellables: Set<AnyCancellable> = []
  private let store: NetworkInspectorStore

  init(store: NetworkInspectorStore) {
    self.store = store

    store.$servers
      .receive(on: DispatchQueue.main)
      .sink { [weak self] servers in
        self?.servers = servers
      }
      .store(in: &cancellables)

    store.$items
      .receive(on: DispatchQueue.main)
      .sink { [weak self] items in
        self?.items = items
      }
      .store(in: &cancellables)
  }

  func clearCompleted() {
    store.clearCompleted()
  }

  func setRetainedServerIDs(_ ids: Set<SnapOLinkServerID>) {
    store.setRetainedServerIDs(ids)
  }
}
