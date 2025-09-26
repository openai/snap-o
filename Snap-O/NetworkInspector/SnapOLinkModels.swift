import Foundation


struct SnapONetHeader: Decodable, Hashable, Sendable {
  let name: String
  let value: String
}

struct SnapOLinkServer: Identifiable, Hashable, Sendable {
  struct ID: Hashable, Sendable {
    let deviceID: String
    let socketName: String
  }

  var id: ID { ID(deviceID: deviceID, socketName: socketName) }
  let deviceID: String
  let socketName: String
  let localPort: UInt16
  var hello: SnapONetHelloRecord?
  var lastEventAt: Date?
  var deviceDisplayTitle: String
  var isConnected: Bool
  var appIcon: SnapONetAppIconRecord?
  var wallClockBase: Date?
}

struct SnapOLinkEvent: Identifiable, Sendable {
  let id = UUID()
  let serverID: SnapOLinkServer.ID
  let record: SnapONetRecord
  let receivedAt: Date
}

struct NetworkInspectorRequest: Identifiable, Hashable, Sendable {
  struct ID: Hashable, Sendable {
    let serverID: SnapOLinkServer.ID
    let requestID: String
  }

  var id: ID { ID(serverID: serverID, requestID: requestID) }
  let serverID: SnapOLinkServer.ID
  let requestID: String
  var request: SnapONetRequestWillBeSentRecord?
  var response: SnapONetResponseReceivedRecord?
  var failure: SnapONetRequestFailedRecord?
  let firstSeenAt: Date
  var lastUpdatedAt: Date

  init(
    serverID: SnapOLinkServer.ID,
    request: SnapONetRequestWillBeSentRecord,
    timestamp: Date
  ) {
    self.serverID = serverID
    requestID = request.id
    self.request = request
    response = nil
    failure = nil
    firstSeenAt = timestamp
    lastUpdatedAt = timestamp
  }

  init(
    serverID: SnapOLinkServer.ID,
    requestID: String,
    timestamp: Date
  ) {
    self.serverID = serverID
    self.requestID = requestID
    request = nil
    response = nil
    failure = nil
    firstSeenAt = timestamp
    lastUpdatedAt = timestamp
  }
}

enum NetworkInspectorItemID: Hashable, Sendable {
  case request(NetworkInspectorRequest.ID)
  case webSocket(NetworkInspectorWebSocket.ID)
}

struct NetworkInspectorWebSocket: Identifiable, Hashable, Sendable {
  struct ID: Hashable, Sendable {
    let serverID: SnapOLinkServer.ID
    let socketID: String
  }

  var id: ID { ID(serverID: serverID, socketID: socketID) }
  let serverID: SnapOLinkServer.ID
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
    serverID: SnapOLinkServer.ID,
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
    serverID: SnapOLinkServer.ID,
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
  let schemaVersion: String
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
    schemaVersion = record.schemaVersion
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
    schemaVersion = record.schemaVersion
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
  let schemaVersion: String
  let packageName: String
  let processName: String
  let pid: Int
  let serverStartWallMs: Int64
  let serverStartMonoNs: Int64
  let mode: String
  let capabilities: [String]

  init(
    schemaVersion: String = SnapONetRecordDecoder.defaultSchemaVersion,
    packageName: String,
    processName: String,
    pid: Int,
    serverStartWallMs: Int64,
    serverStartMonoNs: Int64,
    mode: String,
    capabilities: [String] = SnapONetRecordDecoder.defaultCapabilities
  ) {
    self.schemaVersion = schemaVersion
    self.packageName = packageName
    self.processName = processName
    self.pid = pid
    self.serverStartWallMs = serverStartWallMs
    self.serverStartMonoNs = serverStartMonoNs
    self.mode = mode
    self.capabilities = capabilities
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    schemaVersion = try container.decodeIfPresent(String.self, forKey: .schemaVersion)
      ?? SnapONetRecordDecoder.defaultSchemaVersion
    packageName = try container.decode(String.self, forKey: .packageName)
    processName = try container.decode(String.self, forKey: .processName)
    pid = try container.decode(Int.self, forKey: .pid)
    serverStartWallMs = try container.decode(Int64.self, forKey: .serverStartWallMs)
    serverStartMonoNs = try container.decode(Int64.self, forKey: .serverStartMonoNs)
    mode = try container.decode(String.self, forKey: .mode)
    capabilities = try container.decodeIfPresent([String].self, forKey: .capabilities)
      ?? SnapONetRecordDecoder.defaultCapabilities
  }

  private enum CodingKeys: String, CodingKey {
    case schemaVersion
    case packageName
    case processName
    case pid
    case serverStartWallMs
    case serverStartMonoNs
    case mode
    case capabilities
  }
}

struct SnapONetAppIconRecord: Decodable, Hashable, Sendable {
  let schemaVersion: String
  let packageName: String
  let width: Int
  let height: Int
  let format: String
  let base64Data: String

  init(
    schemaVersion: String = SnapONetRecordDecoder.defaultSchemaVersion,
    packageName: String,
    width: Int,
    height: Int,
    format: String = "jpg",
    base64Data: String
  ) {
    self.schemaVersion = schemaVersion
    self.packageName = packageName
    self.width = width
    self.height = height
    self.format = format
    self.base64Data = base64Data
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    schemaVersion = try container.decodeIfPresent(String.self, forKey: .schemaVersion)
      ?? SnapONetRecordDecoder.defaultSchemaVersion
    packageName = try container.decode(String.self, forKey: .packageName)
    width = try container.decode(Int.self, forKey: .width)
    height = try container.decode(Int.self, forKey: .height)
    format = try container.decodeIfPresent(String.self, forKey: .format) ?? "jpg"
    base64Data = try container.decode(String.self, forKey: .base64Data)
  }

  private enum CodingKeys: String, CodingKey {
    case schemaVersion
    case packageName
    case width
    case height
    case format
    case base64Data
  }
}

struct SnapONetReplayCompleteRecord: Decodable, Hashable, Sendable {
  let schemaVersion: String

  init(schemaVersion: String = SnapONetRecordDecoder.defaultSchemaVersion) {
    self.schemaVersion = schemaVersion
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    schemaVersion = try container.decodeIfPresent(String.self, forKey: .schemaVersion)
      ?? SnapONetRecordDecoder.defaultSchemaVersion
  }

  private enum CodingKeys: String, CodingKey {
    case schemaVersion
  }
}

struct SnapONetLifecycleRecord: Decodable, Hashable, Sendable {
  let schemaVersion: String
  let state: String
  let tWallMs: Int64
  let tMonoNs: Int64

  init(
    schemaVersion: String = SnapONetRecordDecoder.defaultSchemaVersion,
    state: String,
    tWallMs: Int64,
    tMonoNs: Int64
  ) {
    self.schemaVersion = schemaVersion
    self.state = state
    self.tWallMs = tWallMs
    self.tMonoNs = tMonoNs
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    schemaVersion = try container.decodeIfPresent(String.self, forKey: .schemaVersion)
      ?? SnapONetRecordDecoder.defaultSchemaVersion
    state = try container.decode(String.self, forKey: .state)
    tWallMs = try container.decode(Int64.self, forKey: .tWallMs)
    tMonoNs = try container.decode(Int64.self, forKey: .tMonoNs)
  }

  private enum CodingKeys: String, CodingKey {
    case schemaVersion
    case state
    case tWallMs
    case tMonoNs
  }
}

protocol SnapONetPerRequestRecord: Decodable, Sendable {
  var schemaVersion: String { get }
  var id: String { get }
  var tWallMs: Int64 { get }
  var tMonoNs: Int64 { get }
}

protocol SnapONetPerWebSocketRecord: Decodable, Sendable {
  var schemaVersion: String { get }
  var id: String { get }
  var tWallMs: Int64 { get }
  var tMonoNs: Int64 { get }
}

struct SnapONetRequestWillBeSentRecord: SnapONetPerRequestRecord, Hashable {
  let schemaVersion: String
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
    schemaVersion: String = SnapONetRecordDecoder.defaultSchemaVersion,
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
    self.schemaVersion = schemaVersion
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
    schemaVersion = try container.decodeIfPresent(String.self, forKey: .schemaVersion)
      ?? SnapONetRecordDecoder.defaultSchemaVersion
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
    case schemaVersion
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
  let schemaVersion: String
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
    schemaVersion: String = SnapONetRecordDecoder.defaultSchemaVersion,
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
    self.schemaVersion = schemaVersion
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
    schemaVersion = try container.decodeIfPresent(String.self, forKey: .schemaVersion)
      ?? SnapONetRecordDecoder.defaultSchemaVersion
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
    case schemaVersion
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

struct SnapONetRequestFailedRecord: SnapONetPerRequestRecord, Hashable {
  let schemaVersion: String
  let id: String
  let tWallMs: Int64
  let tMonoNs: Int64
  let errorKind: String
  let message: String?
  let timings: SnapONetTimings

  init(
    schemaVersion: String = SnapONetRecordDecoder.defaultSchemaVersion,
    id: String,
    tWallMs: Int64,
    tMonoNs: Int64,
    errorKind: String,
    message: String? = nil,
    timings: SnapONetTimings = SnapONetTimings()
  ) {
    self.schemaVersion = schemaVersion
    self.id = id
    self.tWallMs = tWallMs
    self.tMonoNs = tMonoNs
    self.errorKind = errorKind
    self.message = message
    self.timings = timings
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    schemaVersion = try container.decodeIfPresent(String.self, forKey: .schemaVersion)
      ?? SnapONetRecordDecoder.defaultSchemaVersion
    id = try container.decode(String.self, forKey: .id)
    tWallMs = try container.decode(Int64.self, forKey: .tWallMs)
    tMonoNs = try container.decode(Int64.self, forKey: .tMonoNs)
    errorKind = try container.decode(String.self, forKey: .errorKind)
    message = try container.decodeIfPresent(String.self, forKey: .message)
    timings = try container.decodeIfPresent(SnapONetTimings.self, forKey: .timings)
      ?? SnapONetTimings()
  }

  private enum CodingKeys: String, CodingKey {
    case schemaVersion
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
  let schemaVersion: String
  let id: String
  let tWallMs: Int64
  let tMonoNs: Int64
  let url: String
  let headers: [SnapONetHeader]

  init(
    schemaVersion: String = SnapONetRecordDecoder.defaultSchemaVersion,
    id: String,
    tWallMs: Int64,
    tMonoNs: Int64,
    url: String,
    headers: [SnapONetHeader] = []
  ) {
    self.schemaVersion = schemaVersion
    self.id = id
    self.tWallMs = tWallMs
    self.tMonoNs = tMonoNs
    self.url = url
    self.headers = headers
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    schemaVersion = try container.decodeIfPresent(String.self, forKey: .schemaVersion)
      ?? SnapONetRecordDecoder.defaultSchemaVersion
    id = try container.decode(String.self, forKey: .id)
    tWallMs = try container.decode(Int64.self, forKey: .tWallMs)
    tMonoNs = try container.decode(Int64.self, forKey: .tMonoNs)
    url = try container.decode(String.self, forKey: .url)
    headers = try container.decodeIfPresent([SnapONetHeader].self, forKey: .headers) ?? []
  }

  private enum CodingKeys: String, CodingKey {
    case schemaVersion
    case id
    case tWallMs
    case tMonoNs
    case url
    case headers
  }
}

struct SnapONetWebSocketOpenedRecord: SnapONetPerWebSocketRecord, Hashable {
  let schemaVersion: String
  let id: String
  let tWallMs: Int64
  let tMonoNs: Int64
  let code: Int
  let headers: [SnapONetHeader]

  init(
    schemaVersion: String = SnapONetRecordDecoder.defaultSchemaVersion,
    id: String,
    tWallMs: Int64,
    tMonoNs: Int64,
    code: Int,
    headers: [SnapONetHeader] = []
  ) {
    self.schemaVersion = schemaVersion
    self.id = id
    self.tWallMs = tWallMs
    self.tMonoNs = tMonoNs
    self.code = code
    self.headers = headers
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    schemaVersion = try container.decodeIfPresent(String.self, forKey: .schemaVersion)
      ?? SnapONetRecordDecoder.defaultSchemaVersion
    id = try container.decode(String.self, forKey: .id)
    tWallMs = try container.decode(Int64.self, forKey: .tWallMs)
    tMonoNs = try container.decode(Int64.self, forKey: .tMonoNs)
    code = try container.decode(Int.self, forKey: .code)
    headers = try container.decodeIfPresent([SnapONetHeader].self, forKey: .headers) ?? []
  }

  private enum CodingKeys: String, CodingKey {
    case schemaVersion
    case id
    case tWallMs
    case tMonoNs
    case code
    case headers
  }
}

struct SnapONetWebSocketMessageSentRecord: SnapONetPerWebSocketRecord, Hashable {
  let schemaVersion: String
  let id: String
  let tWallMs: Int64
  let tMonoNs: Int64
  let opcode: String
  let preview: String?
  let payloadSize: Int64?
  let enqueued: Bool

  init(
    schemaVersion: String = SnapONetRecordDecoder.defaultSchemaVersion,
    id: String,
    tWallMs: Int64,
    tMonoNs: Int64,
    opcode: String,
    preview: String? = nil,
    payloadSize: Int64? = nil,
    enqueued: Bool
  ) {
    self.schemaVersion = schemaVersion
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
    schemaVersion = try container.decodeIfPresent(String.self, forKey: .schemaVersion)
      ?? SnapONetRecordDecoder.defaultSchemaVersion
    id = try container.decode(String.self, forKey: .id)
    tWallMs = try container.decode(Int64.self, forKey: .tWallMs)
    tMonoNs = try container.decode(Int64.self, forKey: .tMonoNs)
    opcode = try container.decode(String.self, forKey: .opcode)
    preview = try container.decodeIfPresent(String.self, forKey: .preview)
    payloadSize = try container.decodeIfPresent(Int64.self, forKey: .payloadSize)
    enqueued = try container.decode(Bool.self, forKey: .enqueued)
  }

  private enum CodingKeys: String, CodingKey {
    case schemaVersion
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
  let schemaVersion: String
  let id: String
  let tWallMs: Int64
  let tMonoNs: Int64
  let opcode: String
  let preview: String?
  let payloadSize: Int64?

  init(
    schemaVersion: String = SnapONetRecordDecoder.defaultSchemaVersion,
    id: String,
    tWallMs: Int64,
    tMonoNs: Int64,
    opcode: String,
    preview: String? = nil,
    payloadSize: Int64? = nil
  ) {
    self.schemaVersion = schemaVersion
    self.id = id
    self.tWallMs = tWallMs
    self.tMonoNs = tMonoNs
    self.opcode = opcode
    self.preview = preview
    self.payloadSize = payloadSize
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    schemaVersion = try container.decodeIfPresent(String.self, forKey: .schemaVersion)
      ?? SnapONetRecordDecoder.defaultSchemaVersion
    id = try container.decode(String.self, forKey: .id)
    tWallMs = try container.decode(Int64.self, forKey: .tWallMs)
    tMonoNs = try container.decode(Int64.self, forKey: .tMonoNs)
    opcode = try container.decode(String.self, forKey: .opcode)
    preview = try container.decodeIfPresent(String.self, forKey: .preview)
    payloadSize = try container.decodeIfPresent(Int64.self, forKey: .payloadSize)
  }

  private enum CodingKeys: String, CodingKey {
    case schemaVersion
    case id
    case tWallMs
    case tMonoNs
    case opcode
    case preview
    case payloadSize
  }
}

struct SnapONetWebSocketClosingRecord: SnapONetPerWebSocketRecord, Hashable {
  let schemaVersion: String
  let id: String
  let tWallMs: Int64
  let tMonoNs: Int64
  let code: Int
  let reason: String?

  init(
    schemaVersion: String = SnapONetRecordDecoder.defaultSchemaVersion,
    id: String,
    tWallMs: Int64,
    tMonoNs: Int64,
    code: Int,
    reason: String? = nil
  ) {
    self.schemaVersion = schemaVersion
    self.id = id
    self.tWallMs = tWallMs
    self.tMonoNs = tMonoNs
    self.code = code
    self.reason = reason
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    schemaVersion = try container.decodeIfPresent(String.self, forKey: .schemaVersion)
      ?? SnapONetRecordDecoder.defaultSchemaVersion
    id = try container.decode(String.self, forKey: .id)
    tWallMs = try container.decode(Int64.self, forKey: .tWallMs)
    tMonoNs = try container.decode(Int64.self, forKey: .tMonoNs)
    code = try container.decode(Int.self, forKey: .code)
    reason = try container.decodeIfPresent(String.self, forKey: .reason)
  }

  private enum CodingKeys: String, CodingKey {
    case schemaVersion
    case id
    case tWallMs
    case tMonoNs
    case code
    case reason
  }
}

struct SnapONetWebSocketClosedRecord: SnapONetPerWebSocketRecord, Hashable {
  let schemaVersion: String
  let id: String
  let tWallMs: Int64
  let tMonoNs: Int64
  let code: Int
  let reason: String?

  init(
    schemaVersion: String = SnapONetRecordDecoder.defaultSchemaVersion,
    id: String,
    tWallMs: Int64,
    tMonoNs: Int64,
    code: Int,
    reason: String? = nil
  ) {
    self.schemaVersion = schemaVersion
    self.id = id
    self.tWallMs = tWallMs
    self.tMonoNs = tMonoNs
    self.code = code
    self.reason = reason
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    schemaVersion = try container.decodeIfPresent(String.self, forKey: .schemaVersion)
      ?? SnapONetRecordDecoder.defaultSchemaVersion
    id = try container.decode(String.self, forKey: .id)
    tWallMs = try container.decode(Int64.self, forKey: .tWallMs)
    tMonoNs = try container.decode(Int64.self, forKey: .tMonoNs)
    code = try container.decode(Int.self, forKey: .code)
    reason = try container.decodeIfPresent(String.self, forKey: .reason)
  }

  private enum CodingKeys: String, CodingKey {
    case schemaVersion
    case id
    case tWallMs
    case tMonoNs
    case code
    case reason
  }
}

struct SnapONetWebSocketFailedRecord: SnapONetPerWebSocketRecord, Hashable {
  let schemaVersion: String
  let id: String
  let tWallMs: Int64
  let tMonoNs: Int64
  let errorKind: String
  let message: String?

  init(
    schemaVersion: String = SnapONetRecordDecoder.defaultSchemaVersion,
    id: String,
    tWallMs: Int64,
    tMonoNs: Int64,
    errorKind: String,
    message: String? = nil
  ) {
    self.schemaVersion = schemaVersion
    self.id = id
    self.tWallMs = tWallMs
    self.tMonoNs = tMonoNs
    self.errorKind = errorKind
    self.message = message
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    schemaVersion = try container.decodeIfPresent(String.self, forKey: .schemaVersion)
      ?? SnapONetRecordDecoder.defaultSchemaVersion
    id = try container.decode(String.self, forKey: .id)
    tWallMs = try container.decode(Int64.self, forKey: .tWallMs)
    tMonoNs = try container.decode(Int64.self, forKey: .tMonoNs)
    errorKind = try container.decode(String.self, forKey: .errorKind)
    message = try container.decodeIfPresent(String.self, forKey: .message)
  }

  private enum CodingKeys: String, CodingKey {
    case schemaVersion
    case id
    case tWallMs
    case tMonoNs
    case errorKind
    case message
  }
}

struct SnapONetWebSocketCloseRequestedRecord: SnapONetPerWebSocketRecord, Hashable {
  let schemaVersion: String
  let id: String
  let tWallMs: Int64
  let tMonoNs: Int64
  let code: Int
  let reason: String?
  let initiated: String
  let accepted: Bool

  init(
    schemaVersion: String = SnapONetRecordDecoder.defaultSchemaVersion,
    id: String,
    tWallMs: Int64,
    tMonoNs: Int64,
    code: Int,
    reason: String? = nil,
    initiated: String = "client",
    accepted: Bool
  ) {
    self.schemaVersion = schemaVersion
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
    schemaVersion = try container.decodeIfPresent(String.self, forKey: .schemaVersion)
      ?? SnapONetRecordDecoder.defaultSchemaVersion
    id = try container.decode(String.self, forKey: .id)
    tWallMs = try container.decode(Int64.self, forKey: .tWallMs)
    tMonoNs = try container.decode(Int64.self, forKey: .tMonoNs)
    code = try container.decode(Int.self, forKey: .code)
    reason = try container.decodeIfPresent(String.self, forKey: .reason)
    initiated = try container.decodeIfPresent(String.self, forKey: .initiated) ?? "client"
    accepted = try container.decode(Bool.self, forKey: .accepted)
  }

  private enum CodingKeys: String, CodingKey {
    case schemaVersion
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
  let schemaVersion: String
  let id: String
  let tWallMs: Int64
  let tMonoNs: Int64

  init(
    schemaVersion: String = SnapONetRecordDecoder.defaultSchemaVersion,
    id: String,
    tWallMs: Int64,
    tMonoNs: Int64
  ) {
    self.schemaVersion = schemaVersion
    self.id = id
    self.tWallMs = tWallMs
    self.tMonoNs = tMonoNs
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    schemaVersion = try container.decodeIfPresent(String.self, forKey: .schemaVersion)
      ?? SnapONetRecordDecoder.defaultSchemaVersion
    id = try container.decode(String.self, forKey: .id)
    tWallMs = try container.decode(Int64.self, forKey: .tWallMs)
    tMonoNs = try container.decode(Int64.self, forKey: .tMonoNs)
  }

  private enum CodingKeys: String, CodingKey {
    case schemaVersion
    case id
    case tWallMs
    case tMonoNs
  }
}

enum SnapONetRecordDecoder {
  static let defaultSchemaVersion = "1.0"
  static let defaultCapabilities = ["network", "websocket"]
  private struct Discriminator: Decodable {
    let type: String
  }

  static func decode(from data: Data) throws -> SnapONetRecord {
    let decoder = JSONDecoder()
    let discriminator = try decoder.decode(Discriminator.self, from: data)
    switch discriminator.type {
    case "Hello":
      let record = try decoder.decode(SnapONetHelloRecord.self, from: data)
      return .hello(record)
    case "ReplayComplete":
      let record = try decoder.decode(SnapONetReplayCompleteRecord.self, from: data)
      return .replayComplete(record)
    case "Lifecycle":
      let record = try decoder.decode(SnapONetLifecycleRecord.self, from: data)
      return .lifecycle(record)
    case "AppIcon":
      let record = try decoder.decode(SnapONetAppIconRecord.self, from: data)
      return .appIcon(record)
    case "RequestWillBeSent":
      let record = try decoder.decode(SnapONetRequestWillBeSentRecord.self, from: data)
      return .requestWillBeSent(record)
    case "ResponseReceived":
      let record = try decoder.decode(SnapONetResponseReceivedRecord.self, from: data)
      return .responseReceived(record)
    case "RequestFailed":
      let record = try decoder.decode(SnapONetRequestFailedRecord.self, from: data)
      return .requestFailed(record)
    case "WebSocketWillOpen":
      let record = try decoder.decode(SnapONetWebSocketWillOpenRecord.self, from: data)
      return .webSocketWillOpen(record)
    case "WebSocketOpened":
      let record = try decoder.decode(SnapONetWebSocketOpenedRecord.self, from: data)
      return .webSocketOpened(record)
    case "WebSocketMessageSent":
      let record = try decoder.decode(SnapONetWebSocketMessageSentRecord.self, from: data)
      return .webSocketMessageSent(record)
    case "WebSocketMessageReceived":
      let record = try decoder.decode(SnapONetWebSocketMessageReceivedRecord.self, from: data)
      return .webSocketMessageReceived(record)
    case "WebSocketClosing":
      let record = try decoder.decode(SnapONetWebSocketClosingRecord.self, from: data)
      return .webSocketClosing(record)
    case "WebSocketClosed":
      let record = try decoder.decode(SnapONetWebSocketClosedRecord.self, from: data)
      return .webSocketClosed(record)
    case "WebSocketFailed":
      let record = try decoder.decode(SnapONetWebSocketFailedRecord.self, from: data)
      return .webSocketFailed(record)
    case "WebSocketCloseRequested":
      let record = try decoder.decode(SnapONetWebSocketCloseRequestedRecord.self, from: data)
      return .webSocketCloseRequested(record)
    case "WebSocketCancelled":
      let record = try decoder.decode(SnapONetWebSocketCancelledRecord.self, from: data)
      return .webSocketCancelled(record)
    default:
      let raw = String(data: data, encoding: .utf8) ?? "<unparseable>"
      return .unknown(type: discriminator.type, rawJSON: raw)
    }
  }
}
