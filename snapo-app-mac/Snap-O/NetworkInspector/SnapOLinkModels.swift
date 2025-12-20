import Foundation

struct SnapONetHeader: Decodable, Hashable, Sendable {
  let name: String
  let value: String
}

struct SnapOLinkServerID: Hashable, Sendable {
  let deviceID: String
  let socketName: String
}

struct SnapOLinkServer: Identifiable, Hashable, Sendable {
  var id: SnapOLinkServerID { SnapOLinkServerID(deviceID: deviceID, socketName: socketName) }
  let deviceID: String
  let socketName: String
  let localPort: UInt16
  var hello: SnapONetHelloRecord?
  var schemaVersion: Int?
  var isSchemaNewerThanSupported: Bool
  var lastEventAt: Date?
  var deviceDisplayTitle: String
  var isConnected: Bool
  var appIcon: SnapONetAppIconRecord?
  var wallClockBase: Date?
  var packageNameHint: String?
  var features: Set<String> = []
  var hasHello: Bool {
    hello != nil
  }
}

struct SnapOLinkEvent: Identifiable, Sendable {
  let id = UUID()
  let serverID: SnapOLinkServerID
  let record: SnapONetRecord
  let receivedAt: Date
}

struct NetworkInspectorRequestID: Hashable, Sendable {
  let serverID: SnapOLinkServerID
  let requestID: String
}

struct NetworkInspectorRequest: Identifiable, Hashable, Sendable {
  var id: NetworkInspectorRequestID {
    NetworkInspectorRequestID(serverID: serverID, requestID: requestID)
  }

  let serverID: SnapOLinkServerID
  let requestID: String
  var request: SnapONetRequestWillBeSentRecord?
  var response: SnapONetResponseReceivedRecord?
  var failure: SnapONetRequestFailedRecord?
  var streamEvents: [SnapONetResponseStreamEventRecord] = []
  var streamClosed: SnapONetResponseStreamClosedRecord?
  let firstSeenAt: Date
  var lastUpdatedAt: Date

  init(
    serverID: SnapOLinkServerID,
    request: SnapONetRequestWillBeSentRecord,
    timestamp: Date
  ) {
    self.serverID = serverID
    requestID = request.id
    self.request = request
    response = nil
    failure = nil
    streamEvents = []
    streamClosed = nil
    firstSeenAt = timestamp
    lastUpdatedAt = timestamp
  }

  init(
    serverID: SnapOLinkServerID,
    requestID: String,
    timestamp: Date
  ) {
    self.serverID = serverID
    self.requestID = requestID
    request = nil
    response = nil
    failure = nil
    streamEvents = []
    streamClosed = nil
    firstSeenAt = timestamp
    lastUpdatedAt = timestamp
  }
}

extension NetworkInspectorRequest {
  var isLikelyStreamingResponse: Bool {
    if !streamEvents.isEmpty { return true }
    if hasEventStreamHeader(in: response?.headers) { return true }
    if hasEventStreamHeader(in: request?.headers) { return true }
    return false
  }
}

private func hasEventStreamHeader(in headers: [SnapONetHeader]?) -> Bool {
  guard let headers, !headers.isEmpty else { return false }
  for header in headers {
    if header.name.caseInsensitiveCompare("Content-Type") == .orderedSame,
       header.value.localizedCaseInsensitiveContains("text/event-stream") {
      return true
    }
    if header.name.caseInsensitiveCompare("Accept") == .orderedSame,
       header.value.localizedCaseInsensitiveContains("text/event-stream") {
      return true
    }
  }
  return false
}

enum NetworkInspectorItemID: Hashable, Sendable {
  case request(NetworkInspectorRequestID)
  case webSocket(NetworkInspectorWebSocketID)
}

struct NetworkInspectorWebSocketID: Hashable, Sendable {
  let serverID: SnapOLinkServerID
  let socketID: String
}

struct NetworkInspectorWebSocket: Identifiable, Hashable, Sendable {
  var id: NetworkInspectorWebSocketID {
    NetworkInspectorWebSocketID(serverID: serverID, socketID: socketID)
  }

  let serverID: SnapOLinkServerID
  let socketID: String
  var willOpen: SnapONetWebSocketWillOpenRecord?
  var opened: SnapONetWebSocketOpenedRecord?
  var closing: SnapONetWebSocketClosingRecord?
  var closed: SnapONetWebSocketClosedRecord?
  var failed: SnapONetWebSocketFailedRecord?
  var closeRequested: SnapONetWebSocketCloseRequestedRecord?
  var cancelled: SnapONetWebSocketCancelledRecord?
  var messages: [SnapONetWebSocketMessage] = []
  let firstSeenAt: Date
  var lastUpdatedAt: Date

  init(
    serverID: SnapOLinkServerID,
    socketID: String,
    timestamp: Date
  ) {
    self.serverID = serverID
    self.socketID = socketID
    willOpen = nil
    opened = nil
    closing = nil
    closed = nil
    failed = nil
    closeRequested = nil
    cancelled = nil
    messages = []
    firstSeenAt = timestamp
    lastUpdatedAt = timestamp
  }

  init(
    serverID: SnapOLinkServerID,
    willOpen: SnapONetWebSocketWillOpenRecord,
    timestamp: Date
  ) {
    self.serverID = serverID
    socketID = willOpen.id
    self.willOpen = willOpen
    opened = nil
    closing = nil
    closed = nil
    failed = nil
    closeRequested = nil
    cancelled = nil
    messages = []
    firstSeenAt = timestamp
    lastUpdatedAt = timestamp
  }
}

struct SnapONetWebSocketMessage: Hashable, Sendable, Identifiable {
  enum Direction: Hashable, Sendable {
    case outgoing
    case incoming
  }

  let id = UUID()
  let socketID: String
  let direction: Direction
  let opcode: String
  let preview: String?
  let payloadSize: Int64?
  let enqueued: Bool?
  let tWallMs: Int64
  let tMonoNs: Int64
  let timestamp: Date

  init(sent record: SnapONetWebSocketMessageSentRecord) {
    socketID = record.id
    direction = .outgoing
    opcode = record.opcode
    preview = record.preview
    payloadSize = record.payloadSize
    enqueued = record.enqueued
    tWallMs = record.tWallMs
    tMonoNs = record.tMonoNs
    timestamp = Date(timeIntervalSince1970: TimeInterval(record.tWallMs) / 1000)
  }

  init(received record: SnapONetWebSocketMessageReceivedRecord) {
    socketID = record.id
    direction = .incoming
    opcode = record.opcode
    preview = record.preview
    payloadSize = record.payloadSize
    enqueued = nil
    tWallMs = record.tWallMs
    tMonoNs = record.tMonoNs
    timestamp = Date(timeIntervalSince1970: TimeInterval(record.tWallMs) / 1000)
  }
}

enum SnapONetRecord: Sendable {
  case hello(SnapONetHelloRecord)
  case replayComplete(SnapONetReplayCompleteRecord)
  case lifecycle(SnapONetLifecycleRecord)
  case appIcon(SnapONetAppIconRecord)
  case requestWillBeSent(SnapONetRequestWillBeSentRecord)
  case responseReceived(SnapONetResponseReceivedRecord)
  case requestFailed(SnapONetRequestFailedRecord)
  case responseStreamEvent(SnapONetResponseStreamEventRecord)
  case responseStreamClosed(SnapONetResponseStreamClosedRecord)
  case webSocketWillOpen(SnapONetWebSocketWillOpenRecord)
  case webSocketOpened(SnapONetWebSocketOpenedRecord)
  case webSocketMessageSent(SnapONetWebSocketMessageSentRecord)
  case webSocketMessageReceived(SnapONetWebSocketMessageReceivedRecord)
  case webSocketClosing(SnapONetWebSocketClosingRecord)
  case webSocketClosed(SnapONetWebSocketClosedRecord)
  case webSocketFailed(SnapONetWebSocketFailedRecord)
  case webSocketCloseRequested(SnapONetWebSocketCloseRequestedRecord)
  case webSocketCancelled(SnapONetWebSocketCancelledRecord)
  case unknown(type: String, rawJSON: String)
}

struct SnapONetHelloRecord: Decodable, Hashable, Sendable {
  let schemaVersion: Int
  let packageName: String
  let processName: String
  let pid: Int
  let serverStartWallMs: Int64
  let serverStartMonoNs: Int64
  let mode: String
  let features: [SnapOLinkFeatureInfo]

  init(
    schemaVersion: Int = SnapONetRecordDecoder.supportedSchemaVersion,
    packageName: String,
    processName: String,
    pid: Int,
    serverStartWallMs: Int64,
    serverStartMonoNs: Int64,
    mode: String,
    features: [SnapOLinkFeatureInfo] = []
  ) {
    self.schemaVersion = schemaVersion
    self.packageName = packageName
    self.processName = processName
    self.pid = pid
    self.serverStartWallMs = serverStartWallMs
    self.serverStartMonoNs = serverStartMonoNs
    self.mode = mode
    self.features = features
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion)
      ?? SnapONetRecordDecoder.supportedSchemaVersion
    packageName = try container.decode(String.self, forKey: .packageName)
    processName = try container.decode(String.self, forKey: .processName)
    pid = try container.decode(Int.self, forKey: .pid)
    serverStartWallMs = try container.decode(Int64.self, forKey: .serverStartWallMs)
    serverStartMonoNs = try container.decode(Int64.self, forKey: .serverStartMonoNs)
    mode = try container.decode(String.self, forKey: .mode)
    features = try container.decodeIfPresent([SnapOLinkFeatureInfo].self, forKey: .features) ?? []
  }

  private enum CodingKeys: String, CodingKey {
    case schemaVersion
    case packageName
    case processName
    case pid
    case serverStartWallMs
    case serverStartMonoNs
    case mode
    case features
  }
}

struct SnapOLinkFeatureInfo: Decodable, Hashable, Sendable {
  let id: String
}

struct SnapONetAppIconRecord: Decodable, Hashable, Sendable {
  let packageName: String
  let width: Int
  let height: Int
  let format: String
  let base64Data: String

  init(
    packageName: String,
    width: Int,
    height: Int,
    format: String = "jpg",
    base64Data: String
  ) {
    self.packageName = packageName
    self.width = width
    self.height = height
    self.format = format
    self.base64Data = base64Data
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    packageName = try container.decode(String.self, forKey: .packageName)
    width = try container.decode(Int.self, forKey: .width)
    height = try container.decode(Int.self, forKey: .height)
    format = try container.decodeIfPresent(String.self, forKey: .format) ?? "jpg"
    base64Data = try container.decode(String.self, forKey: .base64Data)
  }

  private enum CodingKeys: String, CodingKey {
    case packageName
    case width
    case height
    case format
    case base64Data
  }
}

struct SnapONetReplayCompleteRecord: Decodable, Hashable, Sendable {
  init() {}

  init(from decoder: Decoder) throws {}
}

struct SnapONetLifecycleRecord: Decodable, Hashable, Sendable {
  let state: String
  let tWallMs: Int64
  let tMonoNs: Int64

  init(
    state: String,
    tWallMs: Int64,
    tMonoNs: Int64
  ) {
    self.state = state
    self.tWallMs = tWallMs
    self.tMonoNs = tMonoNs
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    state = try container.decode(String.self, forKey: .state)
    tWallMs = try container.decode(Int64.self, forKey: .tWallMs)
    tMonoNs = try container.decode(Int64.self, forKey: .tMonoNs)
  }

  private enum CodingKeys: String, CodingKey {
    case state
    case tWallMs
    case tMonoNs
  }
}

protocol SnapONetPerRequestRecord: Decodable, Sendable {
  var id: String { get }
  var tWallMs: Int64 { get }
  var tMonoNs: Int64 { get }
}

protocol SnapONetPerWebSocketRecord: Decodable, Sendable {
  var id: String { get }
  var tWallMs: Int64 { get }
  var tMonoNs: Int64 { get }
}

struct SnapONetRequestWillBeSentRecord: SnapONetPerRequestRecord, Hashable {
  let id: String
  let tWallMs: Int64
  let tMonoNs: Int64
  let method: String
  let url: String
  let headers: [SnapONetHeader]
  let bodyPreview: String?
  let body: String?
  let bodyEncoding: String?
  let bodyTruncatedBytes: Int64?
  let bodySize: Int64?

  init(
    id: String,
    tWallMs: Int64,
    tMonoNs: Int64,
    method: String,
    url: String,
    headers: [SnapONetHeader] = [],
    bodyPreview: String? = nil,
    body: String? = nil,
    bodyEncoding: String? = nil,
    bodyTruncatedBytes: Int64? = nil,
    bodySize: Int64? = nil
  ) {
    self.id = id
    self.tWallMs = tWallMs
    self.tMonoNs = tMonoNs
    self.method = method
    self.url = url
    self.headers = headers
    self.bodyPreview = bodyPreview
    self.body = body
    self.bodyEncoding = bodyEncoding
    self.bodyTruncatedBytes = bodyTruncatedBytes
    self.bodySize = bodySize
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(String.self, forKey: .id)
    tWallMs = try container.decode(Int64.self, forKey: .tWallMs)
    tMonoNs = try container.decode(Int64.self, forKey: .tMonoNs)
    method = try container.decode(String.self, forKey: .method)
    url = try container.decode(String.self, forKey: .url)
    headers = try container.decodeIfPresent([SnapONetHeader].self, forKey: .headers) ?? []
    bodyPreview = try container.decodeIfPresent(String.self, forKey: .bodyPreview)
    body = try container.decodeIfPresent(String.self, forKey: .body)
    bodyEncoding = try container.decodeIfPresent(String.self, forKey: .bodyEncoding)
    bodyTruncatedBytes = try container.decodeIfPresent(Int64.self, forKey: .bodyTruncatedBytes)
    bodySize = try container.decodeIfPresent(Int64.self, forKey: .bodySize)
  }

  private enum CodingKeys: String, CodingKey {
    case id
    case tWallMs
    case tMonoNs
    case method
    case url
    case headers
    case bodyPreview
    case body
    case bodyEncoding
    case bodyTruncatedBytes
    case bodySize
  }
}

struct SnapONetResponseReceivedRecord: SnapONetPerRequestRecord, Hashable {
  let id: String
  let tWallMs: Int64
  let tMonoNs: Int64
  let code: Int
  let headers: [SnapONetHeader]
  let body: String?
  let bodyTruncatedBytes: Int64?
  let bodyPreview: String?
  let bodySize: Int64?
  let timings: SnapONetTimings

  init(
    id: String,
    tWallMs: Int64,
    tMonoNs: Int64,
    code: Int,
    headers: [SnapONetHeader] = [],
    body: String? = nil,
    bodyTruncatedBytes: Int64? = nil,
    bodyPreview: String? = nil,
    bodySize: Int64? = nil,
    timings: SnapONetTimings = SnapONetTimings()
  ) {
    self.id = id
    self.tWallMs = tWallMs
    self.tMonoNs = tMonoNs
    self.code = code
    self.headers = headers
    self.body = body
    self.bodyTruncatedBytes = bodyTruncatedBytes
    self.bodyPreview = bodyPreview
    self.bodySize = bodySize
    self.timings = timings
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(String.self, forKey: .id)
    tWallMs = try container.decode(Int64.self, forKey: .tWallMs)
    tMonoNs = try container.decode(Int64.self, forKey: .tMonoNs)
    code = try container.decode(Int.self, forKey: .code)
    headers = try container.decodeIfPresent([SnapONetHeader].self, forKey: .headers) ?? []
    body = try container.decodeIfPresent(String.self, forKey: .body)
    bodyTruncatedBytes = try container.decodeIfPresent(Int64.self, forKey: .bodyTruncatedBytes)
    bodyPreview = try container.decodeIfPresent(String.self, forKey: .bodyPreview)
    bodySize = try container.decodeIfPresent(Int64.self, forKey: .bodySize)
    timings = try container.decodeIfPresent(SnapONetTimings.self, forKey: .timings)
      ?? SnapONetTimings()
  }

  private enum CodingKeys: String, CodingKey {
    case id
    case tWallMs
    case tMonoNs
    case code
    case headers
    case body
    case bodyTruncatedBytes
    case bodyPreview
    case bodySize
    case timings
  }
}

struct SnapONetResponseStreamEventRecord: SnapONetPerRequestRecord, Hashable {
  let id: String
  let tWallMs: Int64
  let tMonoNs: Int64
  let sequence: Int64
  let raw: String

  init(
    id: String,
    tWallMs: Int64,
    tMonoNs: Int64,
    sequence: Int64,
    raw: String
  ) {
    self.id = id
    self.tWallMs = tWallMs
    self.tMonoNs = tMonoNs
    self.sequence = sequence
    self.raw = raw
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(String.self, forKey: .id)
    tWallMs = try container.decode(Int64.self, forKey: .tWallMs)
    tMonoNs = try container.decode(Int64.self, forKey: .tMonoNs)
    sequence = try container.decode(Int64.self, forKey: .sequence)
    raw = try container.decode(String.self, forKey: .raw)
  }

  private enum CodingKeys: String, CodingKey {
    case id
    case tWallMs
    case tMonoNs
    case sequence
    case raw
  }
}

struct SnapONetResponseStreamClosedRecord: SnapONetPerRequestRecord, Hashable {
  let id: String
  let tWallMs: Int64
  let tMonoNs: Int64
  let reason: String
  let message: String?
  let totalEvents: Int64
  let totalBytes: Int64

  init(
    id: String,
    tWallMs: Int64,
    tMonoNs: Int64,
    reason: String,
    message: String? = nil,
    totalEvents: Int64,
    totalBytes: Int64
  ) {
    self.id = id
    self.tWallMs = tWallMs
    self.tMonoNs = tMonoNs
    self.reason = reason
    self.message = message
    self.totalEvents = totalEvents
    self.totalBytes = totalBytes
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(String.self, forKey: .id)
    tWallMs = try container.decode(Int64.self, forKey: .tWallMs)
    tMonoNs = try container.decode(Int64.self, forKey: .tMonoNs)
    reason = try container.decode(String.self, forKey: .reason)
    message = try container.decodeIfPresent(String.self, forKey: .message)
    totalEvents = try container.decode(Int64.self, forKey: .totalEvents)
    totalBytes = try container.decode(Int64.self, forKey: .totalBytes)
  }

  private enum CodingKeys: String, CodingKey {
    case id
    case tWallMs
    case tMonoNs
    case reason
    case message
    case totalEvents
    case totalBytes
  }
}

struct SnapONetRequestFailedRecord: SnapONetPerRequestRecord, Hashable {
  let id: String
  let tWallMs: Int64
  let tMonoNs: Int64
  let errorKind: String
  let message: String?
  let timings: SnapONetTimings

  init(
    id: String,
    tWallMs: Int64,
    tMonoNs: Int64,
    errorKind: String,
    message: String? = nil,
    timings: SnapONetTimings = SnapONetTimings()
  ) {
    self.id = id
    self.tWallMs = tWallMs
    self.tMonoNs = tMonoNs
    self.errorKind = errorKind
    self.message = message
    self.timings = timings
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(String.self, forKey: .id)
    tWallMs = try container.decode(Int64.self, forKey: .tWallMs)
    tMonoNs = try container.decode(Int64.self, forKey: .tMonoNs)
    errorKind = try container.decode(String.self, forKey: .errorKind)
    message = try container.decodeIfPresent(String.self, forKey: .message)
    timings = try container.decodeIfPresent(SnapONetTimings.self, forKey: .timings)
      ?? SnapONetTimings()
  }

  private enum CodingKeys: String, CodingKey {
    case id
    case tWallMs
    case tMonoNs
    case errorKind
    case message
    case timings
  }
}

struct SnapONetTimings: Decodable, Hashable, Sendable {
  let dnsMs: Int64?
  let connectMs: Int64?
  let tlsMs: Int64?
  let requestHeadersMs: Int64?
  let requestBodyMs: Int64?
  let ttfbMs: Int64?
  let responseBodyMs: Int64?
  let totalMs: Int64?

  init(
    dnsMs: Int64? = nil,
    connectMs: Int64? = nil,
    tlsMs: Int64? = nil,
    requestHeadersMs: Int64? = nil,
    requestBodyMs: Int64? = nil,
    ttfbMs: Int64? = nil,
    responseBodyMs: Int64? = nil,
    totalMs: Int64? = nil
  ) {
    self.dnsMs = dnsMs
    self.connectMs = connectMs
    self.tlsMs = tlsMs
    self.requestHeadersMs = requestHeadersMs
    self.requestBodyMs = requestBodyMs
    self.ttfbMs = ttfbMs
    self.responseBodyMs = responseBodyMs
    self.totalMs = totalMs
  }
}

struct SnapONetWebSocketWillOpenRecord: SnapONetPerWebSocketRecord, Hashable {
  let id: String
  let tWallMs: Int64
  let tMonoNs: Int64
  let url: String
  let headers: [SnapONetHeader]

  init(
    id: String,
    tWallMs: Int64,
    tMonoNs: Int64,
    url: String,
    headers: [SnapONetHeader] = []
  ) {
    self.id = id
    self.tWallMs = tWallMs
    self.tMonoNs = tMonoNs
    self.url = url
    self.headers = headers
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(String.self, forKey: .id)
    tWallMs = try container.decode(Int64.self, forKey: .tWallMs)
    tMonoNs = try container.decode(Int64.self, forKey: .tMonoNs)
    url = try container.decode(String.self, forKey: .url)
    headers = try container.decodeIfPresent([SnapONetHeader].self, forKey: .headers) ?? []
  }

  private enum CodingKeys: String, CodingKey {
    case id
    case tWallMs
    case tMonoNs
    case url
    case headers
  }
}

struct SnapONetWebSocketOpenedRecord: SnapONetPerWebSocketRecord, Hashable {
  let id: String
  let tWallMs: Int64
  let tMonoNs: Int64
  let code: Int
  let headers: [SnapONetHeader]

  init(
    id: String,
    tWallMs: Int64,
    tMonoNs: Int64,
    code: Int,
    headers: [SnapONetHeader] = []
  ) {
    self.id = id
    self.tWallMs = tWallMs
    self.tMonoNs = tMonoNs
    self.code = code
    self.headers = headers
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(String.self, forKey: .id)
    tWallMs = try container.decode(Int64.self, forKey: .tWallMs)
    tMonoNs = try container.decode(Int64.self, forKey: .tMonoNs)
    code = try container.decode(Int.self, forKey: .code)
    headers = try container.decodeIfPresent([SnapONetHeader].self, forKey: .headers) ?? []
  }

  private enum CodingKeys: String, CodingKey {
    case id
    case tWallMs
    case tMonoNs
    case code
    case headers
  }
}

struct SnapONetWebSocketMessageSentRecord: SnapONetPerWebSocketRecord, Hashable {
  let id: String
  let tWallMs: Int64
  let tMonoNs: Int64
  let opcode: String
  let preview: String?
  let payloadSize: Int64?
  let enqueued: Bool

  init(
    id: String,
    tWallMs: Int64,
    tMonoNs: Int64,
    opcode: String,
    preview: String? = nil,
    payloadSize: Int64? = nil,
    enqueued: Bool
  ) {
    self.id = id
    self.tWallMs = tWallMs
    self.tMonoNs = tMonoNs
    self.opcode = opcode
    self.preview = preview
    self.payloadSize = payloadSize
    self.enqueued = enqueued
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(String.self, forKey: .id)
    tWallMs = try container.decode(Int64.self, forKey: .tWallMs)
    tMonoNs = try container.decode(Int64.self, forKey: .tMonoNs)
    opcode = try container.decode(String.self, forKey: .opcode)
    preview = try container.decodeIfPresent(String.self, forKey: .preview)
    payloadSize = try container.decodeIfPresent(Int64.self, forKey: .payloadSize)
    enqueued = try container.decode(Bool.self, forKey: .enqueued)
  }

  private enum CodingKeys: String, CodingKey {
    case id
    case tWallMs
    case tMonoNs
    case opcode
    case preview
    case payloadSize
    case enqueued
  }
}

struct SnapONetWebSocketMessageReceivedRecord: SnapONetPerWebSocketRecord, Hashable {
  let id: String
  let tWallMs: Int64
  let tMonoNs: Int64
  let opcode: String
  let preview: String?
  let payloadSize: Int64?

  init(
    id: String,
    tWallMs: Int64,
    tMonoNs: Int64,
    opcode: String,
    preview: String? = nil,
    payloadSize: Int64? = nil
  ) {
    self.id = id
    self.tWallMs = tWallMs
    self.tMonoNs = tMonoNs
    self.opcode = opcode
    self.preview = preview
    self.payloadSize = payloadSize
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(String.self, forKey: .id)
    tWallMs = try container.decode(Int64.self, forKey: .tWallMs)
    tMonoNs = try container.decode(Int64.self, forKey: .tMonoNs)
    opcode = try container.decode(String.self, forKey: .opcode)
    preview = try container.decodeIfPresent(String.self, forKey: .preview)
    payloadSize = try container.decodeIfPresent(Int64.self, forKey: .payloadSize)
  }

  private enum CodingKeys: String, CodingKey {
    case id
    case tWallMs
    case tMonoNs
    case opcode
    case preview
    case payloadSize
  }
}

struct SnapONetWebSocketClosingRecord: SnapONetPerWebSocketRecord, Hashable {
  let id: String
  let tWallMs: Int64
  let tMonoNs: Int64
  let code: Int
  let reason: String?

  init(
    id: String,
    tWallMs: Int64,
    tMonoNs: Int64,
    code: Int,
    reason: String? = nil
  ) {
    self.id = id
    self.tWallMs = tWallMs
    self.tMonoNs = tMonoNs
    self.code = code
    self.reason = reason
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(String.self, forKey: .id)
    tWallMs = try container.decode(Int64.self, forKey: .tWallMs)
    tMonoNs = try container.decode(Int64.self, forKey: .tMonoNs)
    code = try container.decode(Int.self, forKey: .code)
    reason = try container.decodeIfPresent(String.self, forKey: .reason)
  }

  private enum CodingKeys: String, CodingKey {
    case id
    case tWallMs
    case tMonoNs
    case code
    case reason
  }
}

struct SnapONetWebSocketClosedRecord: SnapONetPerWebSocketRecord, Hashable {
  let id: String
  let tWallMs: Int64
  let tMonoNs: Int64
  let code: Int
  let reason: String?

  init(
    id: String,
    tWallMs: Int64,
    tMonoNs: Int64,
    code: Int,
    reason: String? = nil
  ) {
    self.id = id
    self.tWallMs = tWallMs
    self.tMonoNs = tMonoNs
    self.code = code
    self.reason = reason
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(String.self, forKey: .id)
    tWallMs = try container.decode(Int64.self, forKey: .tWallMs)
    tMonoNs = try container.decode(Int64.self, forKey: .tMonoNs)
    code = try container.decode(Int.self, forKey: .code)
    reason = try container.decodeIfPresent(String.self, forKey: .reason)
  }

  private enum CodingKeys: String, CodingKey {
    case id
    case tWallMs
    case tMonoNs
    case code
    case reason
  }
}

struct SnapONetWebSocketFailedRecord: SnapONetPerWebSocketRecord, Hashable {
  let id: String
  let tWallMs: Int64
  let tMonoNs: Int64
  let errorKind: String
  let message: String?

  init(
    id: String,
    tWallMs: Int64,
    tMonoNs: Int64,
    errorKind: String,
    message: String? = nil
  ) {
    self.id = id
    self.tWallMs = tWallMs
    self.tMonoNs = tMonoNs
    self.errorKind = errorKind
    self.message = message
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(String.self, forKey: .id)
    tWallMs = try container.decode(Int64.self, forKey: .tWallMs)
    tMonoNs = try container.decode(Int64.self, forKey: .tMonoNs)
    errorKind = try container.decode(String.self, forKey: .errorKind)
    message = try container.decodeIfPresent(String.self, forKey: .message)
  }

  private enum CodingKeys: String, CodingKey {
    case id
    case tWallMs
    case tMonoNs
    case errorKind
    case message
  }
}

struct SnapONetWebSocketCloseRequestedRecord: SnapONetPerWebSocketRecord, Hashable {
  let id: String
  let tWallMs: Int64
  let tMonoNs: Int64
  let code: Int
  let reason: String?
  let initiated: String
  let accepted: Bool

  init(
    id: String,
    tWallMs: Int64,
    tMonoNs: Int64,
    code: Int,
    reason: String? = nil,
    initiated: String = "client",
    accepted: Bool
  ) {
    self.id = id
    self.tWallMs = tWallMs
    self.tMonoNs = tMonoNs
    self.code = code
    self.reason = reason
    self.initiated = initiated
    self.accepted = accepted
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(String.self, forKey: .id)
    tWallMs = try container.decode(Int64.self, forKey: .tWallMs)
    tMonoNs = try container.decode(Int64.self, forKey: .tMonoNs)
    code = try container.decode(Int.self, forKey: .code)
    reason = try container.decodeIfPresent(String.self, forKey: .reason)
    initiated = try container.decodeIfPresent(String.self, forKey: .initiated) ?? "client"
    accepted = try container.decode(Bool.self, forKey: .accepted)
  }

  private enum CodingKeys: String, CodingKey {
    case id
    case tWallMs
    case tMonoNs
    case code
    case reason
    case initiated
    case accepted
  }
}

struct SnapONetWebSocketCancelledRecord: SnapONetPerWebSocketRecord, Hashable {
  let id: String
  let tWallMs: Int64
  let tMonoNs: Int64

  init(
    id: String,
    tWallMs: Int64,
    tMonoNs: Int64
  ) {
    self.id = id
    self.tWallMs = tWallMs
    self.tMonoNs = tMonoNs
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(String.self, forKey: .id)
    tWallMs = try container.decode(Int64.self, forKey: .tWallMs)
    tMonoNs = try container.decode(Int64.self, forKey: .tMonoNs)
  }

  private enum CodingKeys: String, CodingKey {
    case id
    case tWallMs
    case tMonoNs
  }
}

enum SnapONetRecordDecoder {
  static let supportedSchemaVersion = 2
  private struct Discriminator: Decodable {
    let type: String
  }

  static func decode(from data: Data) throws -> SnapONetRecord {
    // Peek at the top-level JSON to allow FeatureEvent envelope.
    let top = try JSONSerialization.jsonObject(with: data, options: [])
    guard let dict = top as? [String: Any],
          let type = dict["type"] as? String else {
      let raw = String(data: data, encoding: .utf8) ?? "<unparseable>"
      return .unknown(type: "<missing-type>", rawJSON: raw)
    }

    switch type {
    case "FeatureEvent":
      return try decodeFeatureEvent(from: dict, raw: data)
    case "Hello":
      return try JSONDecoder().decode(SnapONetHelloRecord.self, from: data).asEnum
    case "ReplayComplete":
      return try JSONDecoder().decode(SnapONetReplayCompleteRecord.self, from: data).asEnum
    case "Lifecycle":
      return try JSONDecoder().decode(SnapONetLifecycleRecord.self, from: data).asEnum
    case "AppIcon":
      return try JSONDecoder().decode(SnapONetAppIconRecord.self, from: data).asEnum
    case "RequestWillBeSent",
         "ResponseReceived",
         "ResponseStreamEvent",
         "ResponseStreamClosed",
         "RequestFailed",
         "WebSocketWillOpen",
         "WebSocketOpened",
         "WebSocketMessageSent",
         "WebSocketMessageReceived",
         "WebSocketClosing",
         "WebSocketClosed",
         "WebSocketFailed",
         "WebSocketCloseRequested",
         "WebSocketCancelled":
      // Back-compat: allow legacy unwrapped network records.
      return try decodeNetworkPayload(from: data)
    default:
      let raw = String(data: data, encoding: .utf8) ?? "<unparseable>"
      return .unknown(type: type, rawJSON: raw)
    }
  }

  private static func decodeFeatureEvent(from dict: [String: Any], raw: Data) throws -> SnapONetRecord {
    guard let feature = dict["feature"] as? String,
          let payloadObj = dict["payload"] else {
      let rawJSON = String(data: raw, encoding: .utf8) ?? "<unparseable>"
      return .unknown(type: "FeatureEvent", rawJSON: rawJSON)
    }
    let payloadData = try JSONSerialization.data(withJSONObject: payloadObj, options: [])
    switch feature {
    case "network":
      return try decodeNetworkPayload(from: payloadData)
    default:
      let rawJSON = String(data: raw, encoding: .utf8) ?? "<unparseable>"
      return .unknown(type: "FeatureEvent(\(feature))", rawJSON: rawJSON)
    }
  }

  private static func decodeNetworkPayload(from data: Data) throws -> SnapONetRecord {
    let decoder = JSONDecoder()
    let discriminator = try decoder.decode(Discriminator.self, from: data)
    switch discriminator.type {
    case "RequestWillBeSent":
      return try .requestWillBeSent(decoder.decode(SnapONetRequestWillBeSentRecord.self, from: data))
    case "ResponseReceived":
      return try .responseReceived(decoder.decode(SnapONetResponseReceivedRecord.self, from: data))
    case "ResponseStreamEvent":
      return try .responseStreamEvent(decoder.decode(SnapONetResponseStreamEventRecord.self, from: data))
    case "ResponseStreamClosed":
      return try .responseStreamClosed(decoder.decode(SnapONetResponseStreamClosedRecord.self, from: data))
    case "RequestFailed":
      return try .requestFailed(decoder.decode(SnapONetRequestFailedRecord.self, from: data))
    case "WebSocketWillOpen":
      return try .webSocketWillOpen(decoder.decode(SnapONetWebSocketWillOpenRecord.self, from: data))
    case "WebSocketOpened":
      return try .webSocketOpened(decoder.decode(SnapONetWebSocketOpenedRecord.self, from: data))
    case "WebSocketMessageSent":
      return try .webSocketMessageSent(decoder.decode(SnapONetWebSocketMessageSentRecord.self, from: data))
    case "WebSocketMessageReceived":
      return try .webSocketMessageReceived(decoder.decode(SnapONetWebSocketMessageReceivedRecord.self, from: data))
    case "WebSocketClosing":
      return try .webSocketClosing(decoder.decode(SnapONetWebSocketClosingRecord.self, from: data))
    case "WebSocketClosed":
      return try .webSocketClosed(decoder.decode(SnapONetWebSocketClosedRecord.self, from: data))
    case "WebSocketFailed":
      return try .webSocketFailed(decoder.decode(SnapONetWebSocketFailedRecord.self, from: data))
    case "WebSocketCloseRequested":
      return try .webSocketCloseRequested(decoder.decode(SnapONetWebSocketCloseRequestedRecord.self, from: data))
    case "WebSocketCancelled":
      return try .webSocketCancelled(decoder.decode(SnapONetWebSocketCancelledRecord.self, from: data))
    default:
      let raw = String(data: data, encoding: .utf8) ?? "<unparseable>"
      return .unknown(type: discriminator.type, rawJSON: raw)
    }
  }
}

private extension SnapONetHelloRecord { var asEnum: SnapONetRecord { .hello(self) } }
private extension SnapONetReplayCompleteRecord { var asEnum: SnapONetRecord { .replayComplete(self) } }
private extension SnapONetLifecycleRecord { var asEnum: SnapONetRecord { .lifecycle(self) } }
private extension SnapONetAppIconRecord { var asEnum: SnapONetRecord { .appIcon(self) } }
