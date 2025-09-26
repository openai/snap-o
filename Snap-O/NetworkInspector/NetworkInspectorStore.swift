import AppKit
import Combine
import Foundation

@MainActor
final class NetworkInspectorStore: ObservableObject {
  @Published private(set) var servers: [NetworkInspectorServerViewModel] = []
  @Published private(set) var items: [NetworkInspectorListItemViewModel] = []

  private let service: NetworkInspectorService
  private var tasks: [Task<Void, Never>] = []
  private var serverLookup: [NetworkInspectorServer.ID: NetworkInspectorServerViewModel] = [:]
  private var latestRequests: [NetworkInspectorRequest] = []
  private var latestWebSockets: [NetworkInspectorWebSocket] = []
  private var requestLookup: [NetworkInspectorRequest.ID: NetworkInspectorRequestViewModel] = [:]
  private var webSocketLookup: [NetworkInspectorWebSocket.ID: NetworkInspectorWebSocketViewModel] = [:]

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
        serverLookup = Dictionary(uniqueKeysWithValues: viewModels.map { ($0.id, $0) })
        rebuildViewModels()
      }
    })

    tasks.append(Task { [weak self] in
      guard let self else { return }
      for await requests in await self.service.requestsStream() {
        latestRequests = requests
        rebuildViewModels()
      }
    })

    tasks.append(Task { [weak self] in
      guard let self else { return }
      for await webSockets in await self.service.webSocketsStream() {
        latestWebSockets = webSockets
        rebuildViewModels()
      }
    })
  }

  deinit {
    for task in tasks {
      task.cancel()
    }
  }

  private func rebuildViewModels() {
    let requestViewModels = latestRequests.map { request in
      let server = serverLookup[request.serverID]
      return NetworkInspectorRequestViewModel(request: request, server: server)
    }
    requestLookup = Dictionary(uniqueKeysWithValues: requestViewModels.map { ($0.id, $0) })

    let webSocketViewModels = latestWebSockets.map { session in
      let server = serverLookup[session.serverID]
      return NetworkInspectorWebSocketViewModel(session: session, server: server)
    }
    webSocketLookup = Dictionary(uniqueKeysWithValues: webSocketViewModels.map { ($0.id, $0) })

    let combined: [NetworkInspectorListItemViewModel] =
      requestViewModels.map { NetworkInspectorListItemViewModel(kind: .request($0), firstSeenAt: $0.firstSeenAt) } +
      webSocketViewModels.map { NetworkInspectorListItemViewModel(kind: .webSocket($0), firstSeenAt: $0.firstSeenAt) }

    items = combined.sorted { lhs, rhs in
      if lhs.firstSeenAt == rhs.firstSeenAt {
        return lhs.id.hashValue < rhs.id.hashValue
      }
      return lhs.firstSeenAt < rhs.firstSeenAt
    }
  }

  func detail(for id: NetworkInspectorItemID) -> NetworkInspectorDetailViewModel? {
    switch id {
    case .request(let requestID):
      guard let viewModel = requestLookup[requestID] else { return nil }
      return .request(viewModel)
    case .webSocket(let socketID):
      guard let viewModel = webSocketLookup[socketID] else { return nil }
      return .webSocket(viewModel)
    }
  }

  func setRetainedServerIDs(_ ids: Set<NetworkInspectorServer.ID>) {
    Task {
      await service.updateRetainedServers(ids)
    }
  }
}

struct NetworkInspectorServerViewModel: Identifiable {
  let id: NetworkInspectorServer.ID
  let displayName: String
  let helloSummary: String?
  let deviceDisplayTitle: String
  let isConnected: Bool
  let deviceID: String
  let pid: Int?
  let appIcon: NSImage?
  let wallClockBase: Date?

  init(server: NetworkInspectorServer) {
    id = server.id
    deviceID = server.id.deviceID
    deviceDisplayTitle = server.deviceDisplayTitle
    isConnected = server.isConnected
    pid = server.hello?.pid
    if let iconRecord = server.appIcon,
       let data = Data(base64Encoded: iconRecord.base64Data),
       let image = NSImage(data: data) {
      appIcon = image
    } else {
      appIcon = nil
    }
    wallClockBase = server.wallClockBase
    if let hello = server.hello {
      displayName = hello.packageName
      helloSummary = server.deviceDisplayTitle
    } else {
      displayName = server.socketName
      helloSummary = server.deviceDisplayTitle
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
  let serverID: NetworkInspectorServer.ID
  let status: Status
  let serverSummary: String
  let requestIdentifier: String
  let timingSummary: String
  let requestHeaders: [Header]
  let responseHeaders: [Header]
  let primaryPathComponent: String
  let secondaryPath: String
  let firstSeenAt: Date
  let lastUpdatedAt: Date
  let responseBody: ResponseBody?

  init(request: NetworkInspectorRequest, server: NetworkInspectorServerViewModel?) {
    id = request.id
    serverID = request.serverID
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

    firstSeenAt = request.firstSeenAt
    lastUpdatedAt = request.lastUpdatedAt

    let startMillis = request.request?.tWallMs
    let endMillis = request.failure?.tWallMs ?? request.response?.tWallMs
    timingSummary = Self.makeTimingSummary(status: status,
                                           startMillis: startMillis,
                                           endMillis: endMillis,
                                           fallbackStart: request.firstSeenAt,
                                           fallbackEnd: request.lastUpdatedAt,
                                           wallClockBase: server?.wallClockBase)

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
        .sorted { $0.key.lowercased() < $1.key.lowercased() }
        .map { Header(name: $0.key, value: $0.value) }
    } else {
      requestHeaders = []
    }

    if let responseRecord = request.response {
      responseHeaders = responseRecord.headers
        .sorted { $0.key.lowercased() < $1.key.lowercased() }
        .map { Header(name: $0.key, value: $0.value) }
    } else {
      responseHeaders = []
    }

    if let responseRecord = request.response {
      if let text = responseRecord.body ?? responseRecord.bodyPreview {
        let capturedBytes = Int64(text.lengthOfBytes(using: .utf8))
        let contentType = responseRecord.headers.first { $0.key.caseInsensitiveCompare("Content-Type") == .orderedSame }?.value
        let prettyPrinted = ResponseBody.prettyPrintedJSON(from: text)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let startsLikeJSON = trimmed.first.map { ["{", "[", "\""].contains(String($0)) } ?? false
        let isLikelyJSON =
          (contentType?.localizedCaseInsensitiveContains("json") ?? false) ||
          prettyPrinted != nil ||
          startsLikeJSON

        responseBody = ResponseBody(
          rawText: text,
          prettyPrintedText: prettyPrinted,
          isLikelyJSON: isLikelyJSON,
          isPreview: responseRecord.body == nil,
          truncatedBytes: responseRecord.bodyTruncatedBytes,
          totalBytes: responseRecord.bodySize,
          capturedBytes: capturedBytes
        )
      } else {
        responseBody = nil
      }
    } else {
      responseBody = nil
    }
  }

  struct Header: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let value: String
  }

  struct ResponseBody: Hashable {
    let rawText: String
    let prettyPrintedText: String?
    let isLikelyJSON: Bool
    let isPreview: Bool
    let truncatedBytes: Int64?
    let totalBytes: Int64?
    let capturedBytes: Int64

    static func prettyPrintedJSON(from text: String) -> String? {
      guard let data = text.data(using: .utf8) else { return nil }
      do {
        let object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        let prettyData = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted])
        return String(data: prettyData, encoding: .utf8)
      } catch {
        return nil
      }
    }
  }

  static func makeTimingSummary(status: Status,
                                startMillis: Int64?,
                                endMillis: Int64?,
                                fallbackStart: Date,
                                fallbackEnd: Date,
                                wallClockBase: Date?) -> String {
    let startDate = date(fromMillis: startMillis, base: wallClockBase) ?? fallbackStart
    let endDate = date(fromMillis: endMillis, base: wallClockBase) ?? fallbackEnd

    switch status {
    case .pending:
      let startString = startDate.formatted(date: .omitted, time: .standard)
      return "Started at \(startString)"
    case .success, .failure:
      let durationSeconds: Double
      if let start = startMillis, let end = endMillis, end > start {
        durationSeconds = Double(end - start) / 1000
      } else {
        durationSeconds = max(endDate.timeIntervalSince(startDate), 0)
      }
      let durationString = formattedDuration(durationSeconds)
      let startString = startDate.formatted(date: .omitted, time: .standard)
      return "\(durationString) (started at \(startString))"
    }
  }

  private static func date(fromMillis millis: Int64?, base: Date?) -> Date? {
    guard let millis, let base else { return nil }
    return base.addingTimeInterval(Double(millis) / 1000)
  }

  private static func formattedDuration(_ duration: Double) -> String {
    if duration < 1 {
      return String(format: "%.0f ms", duration * 1000)
    } else if duration < 10 {
      return String(format: "%.2f s", duration)
    } else if duration < 60 {
      return String(format: "%.1f s", duration)
    } else {
      let formatter = DateComponentsFormatter()
      formatter.allowedUnits = [.minute, .second]
      formatter.unitsStyle = .abbreviated
      return formatter.string(from: duration) ?? String(format: "%.1f s", duration)
    }
  }
}

struct NetworkInspectorWebSocketViewModel: Identifiable {
  struct Message: Identifiable, Hashable {
    let id: UUID
    let direction: SnapONetWebSocketMessage.Direction
    let opcode: String
    let preview: String?
    let payloadSize: Int64?
    let enqueued: Bool?
    let timestamp: Date

    init(message: SnapONetWebSocketMessage) {
      id = message.id
      direction = message.direction
      opcode = message.opcode
      preview = message.preview
      payloadSize = message.payloadSize
      enqueued = message.enqueued
      timestamp = message.timestamp
    }
  }

  let id: NetworkInspectorWebSocket.ID
  let method: String
  let url: String
  let serverID: NetworkInspectorServer.ID
  let status: NetworkInspectorRequestViewModel.Status
  let serverSummary: String
  let socketIdentifier: String
  let timingSummary: String
  let requestHeaders: [NetworkInspectorRequestViewModel.Header]
  let responseHeaders: [NetworkInspectorRequestViewModel.Header]
  let primaryPathComponent: String
  let secondaryPath: String
  let willOpen: SnapONetWebSocketWillOpenRecord?
  let opened: SnapONetWebSocketOpenedRecord?
  let closing: SnapONetWebSocketClosingRecord?
  let closed: SnapONetWebSocketClosedRecord?
  let failed: SnapONetWebSocketFailedRecord?
  let closeRequested: SnapONetWebSocketCloseRequestedRecord?
  let cancelled: SnapONetWebSocketCancelledRecord?
  let messages: [Message]
  let firstSeenAt: Date
  let lastUpdatedAt: Date

  init(session: NetworkInspectorWebSocket, server: NetworkInspectorServerViewModel?) {
    id = session.id
    serverID = session.serverID

    let urlString = session.willOpen?.url ?? "websocket://\(session.socketID)"
    url = urlString

    if let scheme = URLComponents(string: urlString)?.scheme?.uppercased(), !scheme.isEmpty {
      method = scheme
    } else {
      method = "WS"
    }

    if let failure = session.failed {
      status = .failure(message: failure.message)
    } else if session.cancelled != nil {
      status = .failure(message: "Cancelled")
    } else if let closed = session.closed {
      status = .success(code: closed.code)
    } else if let closing = session.closing {
      status = .success(code: closing.code)
    } else if let opened = session.opened {
      status = .success(code: opened.code)
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
      serverSummary = "\(session.serverID.deviceID) • \(session.serverID.socketName)"
    }

    socketIdentifier = "Socket ID: \(session.socketID)"

    firstSeenAt = session.firstSeenAt
    lastUpdatedAt = session.lastUpdatedAt

    let startMillis = session.willOpen?.tWallMs ?? session.opened?.tWallMs
    let endMillis = session.failed?.tWallMs
      ?? session.closed?.tWallMs
      ?? session.closing?.tWallMs
      ?? session.messages.last?.tWallMs

    timingSummary = NetworkInspectorRequestViewModel.makeTimingSummary(status: status,
                                                                       startMillis: startMillis,
                                                                       endMillis: endMillis,
                                                                       fallbackStart: session.firstSeenAt,
                                                                       fallbackEnd: session.lastUpdatedAt,
                                                                       wallClockBase: server?.wallClockBase)

    let components = URLComponents(string: urlString)
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
      primaryPathComponent = components?.host ?? session.socketID
      if let query = components?.percentEncodedQuery, !query.isEmpty {
        secondaryPath = "?\(query)"
      } else {
        secondaryPath = ""
      }
    }

    requestHeaders = session.willOpen?.headers
      .sorted { $0.key.lowercased() < $1.key.lowercased() }
      .map { NetworkInspectorRequestViewModel.Header(name: $0.key, value: $0.value) } ?? []

    responseHeaders = session.opened?.headers
      .sorted { $0.key.lowercased() < $1.key.lowercased() }
      .map { NetworkInspectorRequestViewModel.Header(name: $0.key, value: $0.value) } ?? []

    willOpen = session.willOpen
    opened = session.opened
    closing = session.closing
    closed = session.closed
    failed = session.failed
    closeRequested = session.closeRequested
    cancelled = session.cancelled

    messages = session.messages.map(Message.init)
  }
}

struct NetworkInspectorListItemViewModel: Identifiable {
  enum Kind {
    case request(NetworkInspectorRequestViewModel)
    case webSocket(NetworkInspectorWebSocketViewModel)
  }

  let kind: Kind
  let firstSeenAt: Date

  var id: NetworkInspectorItemID {
    switch kind {
    case .request(let request):
      .request(request.id)
    case .webSocket(let webSocket):
      .webSocket(webSocket.id)
    }
  }

  var method: String {
    switch kind {
    case .request(let request):
      request.method
    case .webSocket(let webSocket):
      webSocket.method
    }
  }

  var status: NetworkInspectorRequestViewModel.Status {
    switch kind {
    case .request(let request):
      request.status
    case .webSocket(let webSocket):
      webSocket.status
    }
  }

  var serverID: NetworkInspectorServer.ID {
    switch kind {
    case .request(let request):
      request.serverID
    case .webSocket(let webSocket):
      webSocket.serverID
    }
  }

  var primaryPathComponent: String {
    switch kind {
    case .request(let request):
      request.primaryPathComponent
    case .webSocket(let webSocket):
      webSocket.primaryPathComponent
    }
  }

  var secondaryPath: String {
    switch kind {
    case .request(let request):
      request.secondaryPath
    case .webSocket(let webSocket):
      webSocket.secondaryPath
    }
  }

  var url: String {
    switch kind {
    case .request(let request):
      request.url
    case .webSocket(let webSocket):
      webSocket.url
    }
  }
}

enum NetworkInspectorDetailViewModel {
  case request(NetworkInspectorRequestViewModel)
  case webSocket(NetworkInspectorWebSocketViewModel)
}
