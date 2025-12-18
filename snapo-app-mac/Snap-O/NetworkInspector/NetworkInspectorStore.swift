import AppKit
import Combine
import Foundation
import SwiftUI

@MainActor
final class NetworkInspectorStore: ObservableObject {
  enum RequestDetailSection: Hashable {
    case requestHeaders
    case requestBody
    case responseHeaders
    case responseBody
    case stream
  }

  enum ListSortOrder: String, CaseIterable, Identifiable {
    case oldestFirst
    case newestFirst

    var id: Self { self }

    var label: String {
      switch self {
      case .oldestFirst: "Oldest"
      case .newestFirst: "Newest"
      }
    }

    var systemImage: String {
      switch self {
      case .oldestFirst: "arrow.up"
      case .newestFirst: "arrow.down"
      }
    }
  }

  @Published private(set) var servers: [NetworkInspectorServerViewModel] = []
  @Published private(set) var items: [NetworkInspectorListItemViewModel] = []
  @Published var listSortOrder: ListSortOrder = .oldestFirst {
    didSet {
      rebuildViewModels()
    }
  }

  private let service: NetworkInspectorService
  private var tasks: [Task<Void, Never>] = []
  private var serverLookup: [SnapOLinkServerID: NetworkInspectorServerViewModel] = [:]
  private var latestRequests: [NetworkInspectorRequest] = []
  private var latestWebSockets: [NetworkInspectorWebSocket] = []
  private var requestLookup: [NetworkInspectorRequestID: NetworkInspectorRequest] = [:]
  private var webSocketLookup: [NetworkInspectorWebSocketID: NetworkInspectorWebSocket] = [:]
  private var requestUIStates: [NetworkInspectorRequestID: RequestUIState] = [:]
  private var requestSubjects: [NetworkInspectorRequestID: CurrentValueSubject<NetworkInspectorRequestViewModel?, Never>] = [:]

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
    let previousRequestLookup = requestLookup

    requestLookup = Dictionary(uniqueKeysWithValues: latestRequests.map { ($0.id, $0) })
    webSocketLookup = Dictionary(uniqueKeysWithValues: latestWebSockets.map { ($0.id, $0) })

    let requestSummaries = latestRequests.map { request in
      let server = serverLookup[request.serverID]
      return NetworkInspectorRequestSummary(request: request, server: server)
    }

    let webSocketSummaries = latestWebSockets.map { session in
      let server = serverLookup[session.serverID]
      return NetworkInspectorWebSocketSummary(session: session, server: server)
    }

    let combined: [NetworkInspectorListItemViewModel] =
      requestSummaries.map { NetworkInspectorListItemViewModel(kind: .request($0), firstSeenAt: $0.firstSeenAt) } +
      webSocketSummaries.map { NetworkInspectorListItemViewModel(kind: .webSocket($0), firstSeenAt: $0.firstSeenAt) }

    let comparator: (NetworkInspectorListItemViewModel, NetworkInspectorListItemViewModel) -> Bool = switch listSortOrder {
    case .oldestFirst:
      { lhs, rhs in
        if lhs.firstSeenAt == rhs.firstSeenAt {
          return lhs.id.hashValue < rhs.id.hashValue
        }
        return lhs.firstSeenAt < rhs.firstSeenAt
      }
    case .newestFirst:
      { lhs, rhs in
        if lhs.firstSeenAt == rhs.firstSeenAt {
          return lhs.id.hashValue < rhs.id.hashValue
        }
        return lhs.firstSeenAt > rhs.firstSeenAt
      }
    }

    items = combined.sorted(by: comparator)

    let validRequestIDs = Set(requestSummaries.map(\.id))
    requestUIStates = requestUIStates.filter { validRequestIDs.contains($0.key) }
    notifyRequestObservers(previousRequests: previousRequestLookup)
  }

  private func isCollapsed(
    _ section: RequestDetailSection,
    for requestID: NetworkInspectorRequestID,
    defaultExpanded: Bool
  ) -> Bool {
    guard let state = requestUIStates[requestID] else {
      return !defaultExpanded
    }
    return state.collapsedSections.contains(section)
  }

  private func setSection(
    _ section: RequestDetailSection,
    for requestID: NetworkInspectorRequestID,
    collapsed: Bool,
    defaultExpanded: Bool
  ) {
    ensureUIStateExists(for: requestID)
    var state = requestUIStates[requestID] ?? RequestUIState()
    let currentlyCollapsed = state.collapsedSections.contains(section)

    guard currentlyCollapsed != collapsed else { return }

    if collapsed {
      state.collapsedSections.insert(section)
    } else {
      state.collapsedSections.remove(section)
    }

    requestUIStates[requestID] = state
    objectWillChange.send()
  }

  func bindingForSection(
    _ section: RequestDetailSection,
    requestID: NetworkInspectorRequestID,
    defaultExpanded: Bool = true
  ) -> Binding<Bool> {
    ensureUIStateExists(for: requestID)
    return Binding(
      get: { !self.isCollapsed(section, for: requestID, defaultExpanded: defaultExpanded) },
      set: { self.setSection(section, for: requestID, collapsed: !$0, defaultExpanded: defaultExpanded) }
    )
  }

  func bindingForPrettyPrinted(
    _ section: RequestDetailSection,
    requestID: NetworkInspectorRequestID,
    defaultValue: Bool
  ) -> Binding<Bool> {
    ensureUIStateExists(for: requestID)
    return Binding(
      get: {
        let state = self.requestUIStates[requestID]
        return state?.prettyPrintedSections.contains(section) ?? defaultValue
      },
      set: { newValue in
        var state = self.requestUIStates[requestID] ?? RequestUIState()
        if newValue == defaultValue {
          state.prettyPrintedSections.remove(section)
        } else {
          state.prettyPrintedSections.insert(section)
        }
        self.requestUIStates[requestID] = state
        self.objectWillChange.send()
      }
    )
  }

  func detail(for id: NetworkInspectorItemID) -> NetworkInspectorDetailViewModel? {
    switch id {
    case .request(let requestID):
      guard requestLookup[requestID] != nil else { return nil }
      return .request(requestID)
    case .webSocket(let socketID):
      guard webSocketLookup[socketID] != nil else { return nil }
      return .webSocket(socketID)
    }
  }

  func setRetainedServerIDs(_ ids: Set<SnapOLinkServerID>) {
    Task {
      await service.updateRetainedServers(ids)
    }
  }

  func clearCompleted() {
    Task {
      await service.clearCompletedEntries()
    }
  }

  func requestViewModel(for id: NetworkInspectorRequestID) -> NetworkInspectorRequestViewModel? {
    guard let request = requestLookup[id] else { return nil }
    let server = serverLookup[request.serverID]
    return NetworkInspectorRequestViewModel(request: request, server: server)
  }

  func requestPublisher(for id: NetworkInspectorRequestID) -> AnyPublisher<NetworkInspectorRequestViewModel?, Never> {
    if let subject = requestSubjects[id] {
      return subject.eraseToAnyPublisher()
    }
    let initial = requestViewModel(for: id)
    let subject = CurrentValueSubject<NetworkInspectorRequestViewModel?, Never>(initial)
    requestSubjects[id] = subject
    return subject.eraseToAnyPublisher()
  }

  func webSocketViewModel(for id: NetworkInspectorWebSocketID) -> NetworkInspectorWebSocketViewModel? {
    guard let session = webSocketLookup[id] else { return nil }
    let server = serverLookup[session.serverID]
    return NetworkInspectorWebSocketViewModel(session: session, server: server)
  }
}

struct NetworkInspectorServerViewModel: Identifiable {
  let id: SnapOLinkServerID
  let displayName: String
  let helloSummary: String?
  let deviceDisplayTitle: String
  let isConnected: Bool
  let deviceID: String
  let pid: Int?
  let appIcon: NSImage?
  let wallClockBase: Date?
  let schemaVersion: Int?
  let isSchemaNewerThanSupported: Bool
  let hasHello: Bool

  init(server: SnapOLinkServer) {
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
    hasHello = server.hasHello
    if let hello = server.hello {
      displayName = hello.packageName
      helloSummary = server.deviceDisplayTitle
    } else if let hint = server.packageNameHint, !hint.isEmpty {
      displayName = hint
      helloSummary = server.deviceDisplayTitle
    } else {
      displayName = server.socketName
      helloSummary = server.deviceDisplayTitle
    }
    schemaVersion = server.schemaVersion
    isSchemaNewerThanSupported = server.isSchemaNewerThanSupported
  }
}

struct InspectorTiming {
  let startMillis: Int64?
  let endMillis: Int64?
  let fallbackRange: (start: Date, end: Date)
  let wallClockBase: Date?

  func summary(for status: NetworkInspectorRequestViewModel.Status, now: Date = .now) -> String {
    NetworkInspectorRequestViewModel.makeTimingSummary(
      status: status,
      startMillis: startMillis,
      endMillis: endMillis,
      fallbackRange: fallbackRange,
      wallClockBase: wallClockBase,
      now: now
    )
  }

  var startDate: Date {
    NetworkInspectorRequestViewModel.date(fromMillis: startMillis, base: wallClockBase)
      ?? fallbackRange.start
  }
}

struct NetworkInspectorRequestViewModel: Identifiable {
  enum Status {
    case pending
    case success(code: Int)
    case failure(message: String?)
  }

  let id: NetworkInspectorRequestID
  let method: String
  let url: String
  let serverID: SnapOLinkServerID
  let status: Status
  let serverSummary: String
  let requestIdentifier: String
  let timing: InspectorTiming
  let requestHeaders: [Header]
  let responseHeaders: [Header]
  let requestBody: BodyPayload?
  let primaryPathComponent: String
  let secondaryPath: String
  let firstSeenAt: Date
  let lastUpdatedAt: Date
  let responseBody: BodyPayload?
  let streamEvents: [StreamEvent]
  let streamClosed: StreamClosed?
  let isStreamingResponse: Bool

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
    timing = InspectorTiming(
      startMillis: startMillis,
      endMillis: endMillis,
      fallbackRange: (start: request.firstSeenAt, end: request.lastUpdatedAt),
      wallClockBase: server?.wallClockBase
    )

    let components = URLComponents(string: url)
    let querySuffix = components?.percentEncodedQuery.map { "?\($0)" } ?? ""
    if let path = components?.path, !path.isEmpty {
      let parts = path.split(separator: "/", omittingEmptySubsequences: true)
      primaryPathComponent = (parts.last.map(String.init) ?? path) + querySuffix
      let remaining = parts.dropLast()
      if remaining.isEmpty {
        secondaryPath = ""
      } else {
        let base = "/" + remaining.joined(separator: "/")
        secondaryPath = base
      }
    } else {
      primaryPathComponent = url
      secondaryPath = ""
    }

    if let requestRecord = request.request {
      requestHeaders = requestRecord.headers.map { Header(name: $0.name, value: $0.value) }
      let contentType = requestRecord.headers.first { $0.name.caseInsensitiveCompare("Content-Type") == .orderedSame }?.value
      let encoding = requestRecord.bodyEncoding ?? contentType
      let bodyText = requestRecord.body ?? requestRecord.bodyPreview
      if let bodyText {
        let truncatedBytes = requestRecord.bodyTruncatedBytes
        let isPreview = (requestRecord.body == nil) || (truncatedBytes ?? 0) > 0
        requestBody = Self.makeBodyPayload(
          text: bodyText,
          isPreview: isPreview,
          truncatedBytes: truncatedBytes,
          totalBytes: requestRecord.bodySize,
          encoding: encoding
        )
      } else {
        requestBody = nil
      }
    } else {
      requestHeaders = []
      requestBody = nil
    }

    if let responseRecord = request.response {
      responseHeaders = responseRecord.headers.map { Header(name: $0.name, value: $0.value) }
      if let bodyText = responseRecord.body ?? responseRecord.bodyPreview {
        let contentType = responseRecord.headers.first { $0.name.caseInsensitiveCompare("Content-Type") == .orderedSame }?.value
        responseBody = Self.makeBodyPayload(
          text: bodyText,
          isPreview: responseRecord.body == nil,
          truncatedBytes: responseRecord.bodyTruncatedBytes,
          totalBytes: responseRecord.bodySize,
          encoding: contentType
        )
      } else {
        responseBody = nil
      }
    } else {
      responseHeaders = []
      responseBody = nil
    }

    let events = request.streamEvents.sorted { lhs, rhs in
      if lhs.sequence == rhs.sequence {
        return lhs.tWallMs < rhs.tWallMs
      }
      return lhs.sequence < rhs.sequence
    }
    streamEvents = events.map { StreamEvent(record: $0, wallClockBase: server?.wallClockBase) }
    streamClosed = request.streamClosed.map { StreamClosed(record: $0, wallClockBase: server?.wallClockBase) }
    isStreamingResponse = !streamEvents.isEmpty || streamClosed != nil
  }

  struct Header: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let value: String
  }

  struct BodyPayload: Hashable {
    let rawText: String
    let prettyPrintedText: String?
    let isLikelyJSON: Bool
    let isPreview: Bool
    let truncatedBytes: Int64?
    let totalBytes: Int64?
    let capturedBytes: Int64
    let encoding: String?
    let contentType: String?
    let data: Data?

    static func prettyPrintedJSON(from text: String) -> String? {
      guard let data = text.data(using: .utf8) else { return nil }
      guard (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) != nil else {
        return nil
      }
      return formatJSONPreservingOrder(text)
    }

    private static func formatJSONPreservingOrder(_ text: String) -> String {
      var result = ""
      var indentLevel = 0
      var isInsideString = false
      var isEscaping = false
      let indentUnit = "  "

      func appendIndent(_ level: Int) {
        if level > 0 {
          result.append(String(repeating: indentUnit, count: level))
        }
      }

      for character in text {
        if isEscaping {
          result.append(character)
          isEscaping = false
          continue
        }

        switch character {
        case "\\":
          result.append(character)
          if isInsideString {
            isEscaping = true
          }
        case "\"":
          result.append(character)
          isInsideString.toggle()
        case "{", "[":
          result.append(character)
          guard !isInsideString else { break }
          result.append("\n")
          indentLevel += 1
          appendIndent(indentLevel)
        case "}", "]":
          if isInsideString {
            result.append(character)
          } else {
            trimTrailingWhitespace(&result)
            result.append("\n")
            indentLevel = max(indentLevel - 1, 0)
            appendIndent(indentLevel)
            result.append(character)
          }
        case ",":
          result.append(character)
          if !isInsideString {
            trimTrailingWhitespace(&result)
            result.append("\n")
            appendIndent(indentLevel)
          }
        case ":":
          if isInsideString {
            result.append(character)
          } else {
            result.append(": ")
          }
        case " ", "\n", "\r", "\t":
          if isInsideString {
            result.append(character)
          }
        default:
          result.append(character)
        }
      }

      return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func trimTrailingWhitespace(_ buffer: inout String) {
      while let last = buffer.last, last == " " || last == "\t" {
        buffer.removeLast()
      }
      if buffer.last == "\n" {
        buffer.removeLast()
      }
    }
  }

  struct StreamEvent: Identifiable, Hashable {
    let id: Int64
    let sequence: Int64
    let timestamp: Date
    let eventName: String?
    let data: String?
    let lastEventId: String?
    let retryMillis: Int64?
    let comment: String?
    let raw: String

    init(record: SnapONetResponseStreamEventRecord, wallClockBase: Date?) {
      id = record.sequence
      sequence = record.sequence
      timestamp = NetworkInspectorRequestViewModel.date(fromMillis: record.tWallMs, base: wallClockBase)
        ?? Date(timeIntervalSince1970: TimeInterval(record.tWallMs) / 1000)
      raw = record.raw
      let parsed = StreamEvent.parse(raw: record.raw)
      eventName = parsed.eventName
      data = parsed.data
      lastEventId = parsed.lastEventId
      retryMillis = parsed.retryMillis
      comment = parsed.comment
    }

    private struct ParsedFields {
      let eventName: String?
      let data: String?
      let lastEventId: String?
      let retryMillis: Int64?
      let comment: String?
    }

    private static func parse(raw: String) -> ParsedFields {
      var eventName: String?
      var lastEventId: String?
      var retryMillis: Int64?
      var comments: [String] = []
      var dataLines: [String] = []

      let lines = raw.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
      for line in lines where !line.isEmpty {
        if line.hasPrefix(":") {
          let comment = line.dropFirst().trimmingCharacters(in: .whitespaces)
          if !comment.isEmpty { comments.append(comment) }
          continue
        }

        let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        let field = String(parts.first ?? "")
        var value = parts.count > 1 ? String(parts[1]) : ""
        if value.hasPrefix(" ") {
          value.removeFirst()
        }

        switch field {
        case "event":
          eventName = value
        case "data":
          dataLines.append(value)
        case "id":
          lastEventId = value
        case "retry":
          if let parsed = Int64(value) {
            retryMillis = parsed
          }
        default:
          continue
        }
      }

      let data: String? = if dataLines.isEmpty {
        raw.isEmpty ? "" : nil
      } else {
        dataLines.joined(separator: "\n")
      }

      let commentText = comments.isEmpty ? nil : comments.joined(separator: "\n")

      return ParsedFields(
        eventName: eventName,
        data: data,
        lastEventId: lastEventId,
        retryMillis: retryMillis,
        comment: commentText
      )
    }
  }

  struct StreamClosed: Hashable {
    let timestamp: Date
    let reason: String
    let message: String?
    let totalEvents: Int64
    let totalBytes: Int64

    init(record: SnapONetResponseStreamClosedRecord, wallClockBase: Date?) {
      timestamp = NetworkInspectorRequestViewModel.date(fromMillis: record.tWallMs, base: wallClockBase)
        ?? Date(timeIntervalSince1970: TimeInterval(record.tWallMs) / 1000)
      reason = record.reason
      message = record.message
      totalEvents = record.totalEvents
      totalBytes = record.totalBytes
    }
  }

  static func makeTimingSummary(
    status: Status,
    startMillis: Int64?,
    endMillis: Int64?,
    fallbackRange: (start: Date, end: Date),
    wallClockBase: Date?,
    now: Date = .now
  ) -> String {
    let startDate = date(fromMillis: startMillis, base: wallClockBase) ?? fallbackRange.start
    let endDate = date(fromMillis: endMillis, base: wallClockBase) ?? fallbackRange.end
    let startString = startDate.inspectorTimeString
    let relativeStart = startDate.inspectorRelativeTimeString(reference: now)
    let startSegment = "Started \(relativeStart) at \(startString)"

    switch status {
    case .pending:
      return startSegment
    case .success, .failure:
      let durationSeconds: Double = if let start = startMillis, let end = endMillis, end > start {
        Double(end - start) / 1000
      } else {
        max(endDate.timeIntervalSince(startDate), 0)
      }
      let durationString = formattedDuration(durationSeconds)
      return "\(durationString) total • \(startSegment)"
    }
  }

  static func date(fromMillis millis: Int64?, base: Date?) -> Date? {
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

  private static func makeBodyPayload(
    text: String,
    isPreview: Bool,
    truncatedBytes: Int64?,
    totalBytes: Int64?,
    encoding: String?
  ) -> BodyPayload {
    let capturedBytes = Int64(clamping: text.utf8.count)
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    let encodingMatchesJSON = encoding?.lowercased().contains("json") == true
    let prefixSuggestsJSON = trimmed.first == "{" || trimmed.first == "["

    var isLikelyJSON = encodingMatchesJSON || prefixSuggestsJSON
    let prettyPrinted = BodyPayload.prettyPrintedJSON(from: text)
    if prettyPrinted != nil {
      isLikelyJSON = true
    }

    let normalizedContentType = normalizeContentType(encoding)
    let binaryData = decodeImageDataIfNeeded(text: trimmed, contentType: normalizedContentType)

    return BodyPayload(
      rawText: text,
      prettyPrintedText: prettyPrinted,
      isLikelyJSON: isLikelyJSON,
      isPreview: isPreview,
      truncatedBytes: truncatedBytes,
      totalBytes: totalBytes,
      capturedBytes: capturedBytes,
      encoding: encoding,
      contentType: normalizedContentType,
      data: binaryData
    )
  }

  private static func normalizeContentType(_ rawValue: String?) -> String? {
    guard let raw = rawValue, !raw.isEmpty else { return nil }
    let parts = raw.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: true)
    return parts.first.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
  }

  private static func decodeImageDataIfNeeded(text: String, contentType: String?) -> Data? {
    guard let contentType else { return nil }
    let supportedImageTypes = ["image/png", "image/jpeg", "image/jpg", "image/webp", "image/gif"]
    guard supportedImageTypes.contains(where: { contentType.hasPrefix($0) }) else { return nil }

    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    let base64Payload: String = if let dataURLRange = trimmed.range(of: "base64,", options: [.caseInsensitive]),
                                   dataURLRange.upperBound < trimmed.endIndex {
      String(trimmed[dataURLRange.upperBound...])
    } else if let commaIndex = trimmed.firstIndex(of: ","), trimmed.hasPrefix("data:") {
      String(trimmed[trimmed.index(after: commaIndex)...])
    } else {
      trimmed
    }

    if let data = Data(base64Encoded: base64Payload, options: [.ignoreUnknownCharacters]) {
      return data
    }

    if let data = trimmed.data(using: .utf8), !data.isEmpty {
      return data
    }

    return nil
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

  let id: NetworkInspectorWebSocketID
  let method: String
  let url: String
  let serverID: SnapOLinkServerID
  let status: NetworkInspectorRequestViewModel.Status
  let serverSummary: String
  let socketIdentifier: String
  let timing: InspectorTiming
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

  var isActive: Bool {
    failed == nil && cancelled == nil && closed == nil
  }

  init(session: NetworkInspectorWebSocket, server: NetworkInspectorServerViewModel?) {
    id = session.id
    serverID = session.serverID

    let urlString = session.willOpen?.url ?? "websocket://\(session.socketID)"
    url = urlString

    let scheme = URLComponents(string: urlString)?.scheme
    method = Self.methodBadge(fromScheme: scheme)

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

    timing = InspectorTiming(
      startMillis: startMillis,
      endMillis: endMillis,
      fallbackRange: (start: session.firstSeenAt, end: session.lastUpdatedAt),
      wallClockBase: server?.wallClockBase
    )

    let components = URLComponents(string: urlString)
    if let path = components?.path, !path.isEmpty {
      let parts = path.split(separator: "/", omittingEmptySubsequences: true)
      primaryPathComponent = parts.last.map(String.init) ?? path
      let remaining = parts.dropLast()
      if remaining.isEmpty {
        secondaryPath = components?.percentEncodedQuery.map { "?\($0)" } ?? "\n"
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

    requestHeaders = session.willOpen?.headers.map { NetworkInspectorRequestViewModel.Header(name: $0.name, value: $0.value) } ?? []

    responseHeaders = session.opened?.headers.map { NetworkInspectorRequestViewModel.Header(name: $0.name, value: $0.value) } ?? []

    willOpen = session.willOpen
    opened = session.opened
    closing = session.closing
    closed = session.closed
    failed = session.failed
    closeRequested = session.closeRequested
    cancelled = session.cancelled

    messages = session.messages.map(Message.init)
  }

  private static func methodBadge(fromScheme scheme: String?) -> String {
    guard let scheme, !scheme.isEmpty else { return "WS" }
    switch scheme.lowercased() {
    case "http":
      return "WS"
    case "https":
      return "WSS"
    case "ws":
      return "WS"
    case "wss":
      return "WSS"
    default:
      return scheme.uppercased()
    }
  }
}

enum NetworkInspectorRequestStatus: Equatable {
  case pending
  case success(code: Int)
  case failure(message: String?)
}

struct NetworkInspectorRequestSummary: Identifiable {
  let id: NetworkInspectorRequestID
  let serverID: SnapOLinkServerID
  let method: String
  let url: String
  let primaryPathComponent: String
  let secondaryPath: String
  let status: NetworkInspectorRequestStatus
  let isStreamingResponse: Bool
  let hasClosedStream: Bool
  let firstSeenAt: Date
  let lastUpdatedAt: Date

  init(request: NetworkInspectorRequest, server _: NetworkInspectorServerViewModel?) {
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

    let components = URLComponents(string: url)
    let querySuffix = components?.percentEncodedQuery.map { "?\($0)" } ?? ""
    if let path = components?.path, !path.isEmpty {
      let parts = path.split(separator: "/", omittingEmptySubsequences: true)
      primaryPathComponent = (parts.last.map(String.init) ?? path) + querySuffix
      let remaining = parts.dropLast()
      if remaining.isEmpty {
        secondaryPath = ""
      } else {
        secondaryPath = "/" + remaining.joined(separator: "/")
      }
    } else {
      primaryPathComponent = url
      secondaryPath = ""
    }

    let events = request.streamEvents.sorted { lhs, rhs in
      if lhs.sequence == rhs.sequence {
        return lhs.tWallMs < rhs.tWallMs
      }
      return lhs.sequence < rhs.sequence
    }
    isStreamingResponse = !events.isEmpty || request.streamClosed != nil
    hasClosedStream = request.streamClosed != nil

    firstSeenAt = request.firstSeenAt
    lastUpdatedAt = request.lastUpdatedAt
  }
}

struct NetworkInspectorWebSocketSummary: Identifiable {
  let id: NetworkInspectorWebSocketID
  let serverID: SnapOLinkServerID
  let method: String
  let url: String
  let primaryPathComponent: String
  let secondaryPath: String
  let status: NetworkInspectorRequestStatus
  let showsActiveIndicator: Bool
  let firstSeenAt: Date
  let lastUpdatedAt: Date

  init(session: NetworkInspectorWebSocket, server _: NetworkInspectorServerViewModel?) {
    id = session.id
    serverID = session.serverID

    let urlString = session.willOpen?.url ?? "websocket://\(session.socketID)"
    url = urlString

    let scheme = URLComponents(string: urlString)?.scheme
    method = Self.methodBadge(fromScheme: scheme)

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

    let components = URLComponents(string: urlString)
    let querySuffix = components?.percentEncodedQuery.map { "?\($0)" } ?? ""
    if let path = components?.path, !path.isEmpty {
      let parts = path.split(separator: "/", omittingEmptySubsequences: true)
      primaryPathComponent = (parts.last.map(String.init) ?? path) + querySuffix
      let remaining = parts.dropLast()
      if remaining.isEmpty {
        secondaryPath = ""
      } else {
        secondaryPath = "/" + remaining.joined(separator: "/")
      }
    } else {
      primaryPathComponent = (components?.host ?? session.socketID) + querySuffix
      secondaryPath = ""
    }

    showsActiveIndicator = session.cancelled == nil && session.failed == nil && session.closed == nil
    firstSeenAt = session.firstSeenAt
    lastUpdatedAt = session.lastUpdatedAt
  }

  private static func methodBadge(fromScheme scheme: String?) -> String {
    guard let scheme, !scheme.isEmpty else { return "WS" }
    switch scheme.lowercased() {
    case "http":
      return "WS"
    case "https":
      return "WSS"
    case "ws":
      return "WS"
    case "wss":
      return "WSS"
    default:
      return scheme.uppercased()
    }
  }
}

struct NetworkInspectorListItemViewModel: Identifiable {
  enum Kind {
    case request(NetworkInspectorRequestSummary)
    case webSocket(NetworkInspectorWebSocketSummary)
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
      request.isStreamingResponse && !request.hasClosedStream ? "\(request.method) SSE" : request.method
    case .webSocket(let webSocket):
      webSocket.method
    }
  }

  var status: NetworkInspectorRequestStatus {
    switch kind {
    case .request(let request):
      request.status
    case .webSocket(let webSocket):
      webSocket.status
    }
  }

  var showsActiveIndicator: Bool {
    switch kind {
    case .request(let request):
      request.isStreamingResponse && !request.hasClosedStream
    case .webSocket(let webSocket):
      webSocket.showsActiveIndicator
    }
  }

  var isPending: Bool {
    if case .pending = status {
      return true
    }
    return false
  }

  var serverID: SnapOLinkServerID {
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
  case request(NetworkInspectorRequestID)
  case webSocket(NetworkInspectorWebSocketID)
}

private extension NetworkInspectorStore {
  struct RequestUIState {
    var collapsedSections: Set<RequestDetailSection>
    var prettyPrintedSections: Set<RequestDetailSection>

    init(
      collapsedSections: Set<RequestDetailSection> = [.requestHeaders, .requestBody],
      prettyPrintedSections: Set<RequestDetailSection> = [.requestBody, .responseBody]
    ) {
      self.collapsedSections = collapsedSections
      self.prettyPrintedSections = prettyPrintedSections
    }
  }
}

private extension NetworkInspectorStore {
  func ensureUIStateExists(for requestID: NetworkInspectorRequestID) {
    if requestUIStates[requestID] == nil {
      requestUIStates[requestID] = RequestUIState()
    }
  }

  func notifyRequestObservers(
    previousRequests: [NetworkInspectorRequestID: NetworkInspectorRequest]
  ) {
    guard !requestSubjects.isEmpty else { return }

    var subjectsToRemove: [NetworkInspectorRequestID] = []

    for (id, subject) in requestSubjects {
      guard let current = requestLookup[id] else {
        subject.send(nil)
        subjectsToRemove.append(id)
        continue
      }

      let previous = previousRequests[id]
      let shouldPublish = previous == nil || previous?.lastUpdatedAt != current.lastUpdatedAt

      if shouldPublish {
        let server = serverLookup[current.serverID]
        subject.send(NetworkInspectorRequestViewModel(request: current, server: server))
      }
    }

    if !subjectsToRemove.isEmpty {
      for id in subjectsToRemove {
        requestSubjects.removeValue(forKey: id)
      }
    }
  }
}
