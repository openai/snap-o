import Combine
import Foundation

@MainActor
final class NetworkInspectorStore: ObservableObject {
  @Published private(set) var servers: [NetworkInspectorServerViewModel] = []
  @Published private(set) var requests: [NetworkInspectorRequestViewModel] = []

  private let service: NetworkInspectorService
  private var tasks: [Task<Void, Never>] = []
  private var serverLookup: [NetworkInspectorServer.ID: NetworkInspectorServerViewModel] = [:]
  private var latestRequests: [NetworkInspectorRequest] = []
  private var requestLookup: [NetworkInspectorRequest.ID: NetworkInspectorRequestViewModel] = [:]

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
        self.serverLookup = Dictionary(uniqueKeysWithValues: viewModels.map { ($0.id, $0) })
        self.rebuildRequestViewModels()
      }
    })

    tasks.append(Task { [weak self] in
      guard let self else { return }
      for await requests in await self.service.requestsStream() {
        self.latestRequests = requests
        self.rebuildRequestViewModels()
      }
    })
  }

  deinit {
    for task in tasks {
      task.cancel()
    }
  }

  private func rebuildRequestViewModels() {
    let rebuilt = latestRequests.map { request in
      let server = serverLookup[request.serverID]
      return NetworkInspectorRequestViewModel(request: request, server: server)
    }
    requests = rebuilt
    requestLookup = Dictionary(uniqueKeysWithValues: rebuilt.map { ($0.id, $0) })
  }

  func requestViewModel(for id: NetworkInspectorRequest.ID) -> NetworkInspectorRequestViewModel? {
    requestLookup[id]
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

struct NetworkInspectorRequestViewModel: Identifiable {
  enum Status {
    case pending
    case success(code: Int)
    case failure(message: String?)
  }

  let id: NetworkInspectorRequest.ID
  let method: String
  let url: String
  let status: Status
  let serverSummary: String
  let requestIdentifier: String
  let timingSummary: String
  let requestHeaders: [Header]
  let responseHeaders: [Header]
  let primaryPathComponent: String
  let secondaryPath: String

  init(request: NetworkInspectorRequest, server: NetworkInspectorServerViewModel?) {
    id = request.id
    if let record = request.request {
      method = record.method
      url = record.url
    } else {
      method = "?"
      url = "Request \(request.requestID)"
    }

    if let failure = request.failure {
      status = .failure(message: failure.message)
    } else if let response = request.response {
      status = .success(code: response.code)
    } else {
      status = .pending
    }

    if let server {
      if let summary = server.helloSummary {
        serverSummary = summary
      } else {
        serverSummary = server.displayName
      }
    } else {
      serverSummary = "\(request.serverID.deviceID) • \(request.serverID.socketName)"
    }

    requestIdentifier = "Request ID: \(request.requestID)"

    let start = request.firstSeenAt.formatted(date: .omitted, time: .standard)
    let last = request.lastUpdatedAt.formatted(date: .omitted, time: .standard)
    if request.lastUpdatedAt == request.firstSeenAt {
      timingSummary = "Started at \(start)"
    } else {
      timingSummary = "Updated at \(last) (started \(start))"
    }

    let components = URLComponents(string: url)
    if let path = components?.path, !path.isEmpty {
      let parts = path.split(separator: "/", omittingEmptySubsequences: true)
      primaryPathComponent = parts.last.map(String.init) ?? path
      let remaining = parts.dropLast()
      if remaining.isEmpty {
        secondaryPath = components?.percentEncodedQuery.map { "?\($0)" } ?? ""
      } else {
        let base = "/" + remaining.joined(separator: "/")
        if let query = components?.percentEncodedQuery, !query.isEmpty {
          secondaryPath = base + "?" + query
        } else {
          secondaryPath = base
        }
      }
    } else {
      primaryPathComponent = url
      secondaryPath = ""
    }

    if let requestRecord = request.request {
      requestHeaders = requestRecord.headers
        .sorted(by: { $0.key.lowercased() < $1.key.lowercased() })
        .map { Header(name: $0.key, value: $0.value) }
    } else {
      requestHeaders = []
    }

    if let responseRecord = request.response {
      responseHeaders = responseRecord.headers
        .sorted(by: { $0.key.lowercased() < $1.key.lowercased() })
        .map { Header(name: $0.key, value: $0.value) }
    } else {
      responseHeaders = []
    }
  }

  struct Header: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let value: String
  }
}
