import Combine
import Foundation

@MainActor
final class NetworkInspectorStore: ObservableObject {
  @Published private(set) var servers: [NetworkInspectorServerViewModel] = []
  @Published private(set) var events: [NetworkInspectorEventViewModel] = []

  private let service: NetworkInspectorService
  private var tasks: [Task<Void, Never>] = []

  init(service: NetworkInspectorService) {
    self.service = service

    tasks.append(Task {
      await service.start()
    })

    tasks.append(Task { [weak self] in
      guard let self else { return }
      for await servers in await self.service.serversStream() {
        let viewModels = servers.map(NetworkInspectorServerViewModel.init)
        self.servers = viewModels
      }
    })

    tasks.append(Task { [weak self] in
      guard let self else { return }
      for await event in await self.service.eventsStream() {
        let viewModel = NetworkInspectorEventViewModel(event: event)
        self.events.append(viewModel)
      }
    })
  }

  deinit {
    for task in tasks {
      task.cancel()
    }
  }
}

struct NetworkInspectorServerViewModel: Identifiable {
  let id: NetworkInspectorServer.ID
  let displayName: String
  let helloSummary: String?

  init(server: NetworkInspectorServer) {
    id = server.id
    if let hello = server.hello {
      displayName = "\(hello.processName) (PID \(hello.pid))"
      helloSummary = "\(server.deviceID) • \(hello.packageName)"
    } else {
      displayName = "\(server.deviceID) • \(server.socketName)"
      helloSummary = nil
    }
  }
}

struct NetworkInspectorEventViewModel: Identifiable {
  let id: UUID
  let title: String
  let detail: String?

  init(event: NetworkInspectorEvent) {
    id = event.id
    let timestamp = event.receivedAt.formatted(date: .omitted, time: .standard)

    switch event.record {
    case .hello(let hello):
      title = "Hello – \(hello.processName)"
      detail = "\(timestamp) • Package \(hello.packageName)"
    case .replayComplete:
      title = "Replay Complete"
      detail = timestamp
    case .lifecycle(let lifecycle):
      title = "Lifecycle – \(lifecycle.state)"
      detail = "\(timestamp) • tWallMs=\(lifecycle.tWallMs)"
    case .requestWillBeSent(let request):
      title = "→ \(request.method) \(request.url)"
      if let size = request.bodySize {
        detail = "\(timestamp) • body=\(size)B"
      } else {
        detail = timestamp
      }
    case .responseReceived(let response):
      title = "← \(response.code) for \(response.id)"
      if let size = response.bodySize {
        detail = "\(timestamp) • body=\(size)B"
      } else {
        detail = timestamp
      }
    case .requestFailed(let failure):
      title = "× \(failure.errorKind) for \(failure.id)"
      detail = "\(timestamp) • \(failure.message ?? "Unknown")"
    case .unknown(let type, _):
      title = "Unknown event \(type)"
      detail = timestamp
    }
  }
}
