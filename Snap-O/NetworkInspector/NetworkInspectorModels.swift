import Foundation

struct NetworkInspectorServer: Identifiable, Hashable, Sendable {
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
}

struct NetworkInspectorEvent: Identifiable, Sendable {
  let id = UUID()
  let serverID: NetworkInspectorServer.ID
  let record: SnapONetRecord
  let receivedAt: Date
}

struct NetworkInspectorRequest: Identifiable, Hashable, Sendable {
  struct ID: Hashable, Sendable {
    let serverID: NetworkInspectorServer.ID
    let requestID: String
  }

  var id: ID { ID(serverID: serverID, requestID: requestID) }
  let serverID: NetworkInspectorServer.ID
  let requestID: String
  var request: SnapONetRequestWillBeSentRecord?
  var response: SnapONetResponseReceivedRecord?
  var failure: SnapONetRequestFailedRecord?
  let firstSeenAt: Date
  var lastUpdatedAt: Date

  init(
    serverID: NetworkInspectorServer.ID,
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
    serverID: NetworkInspectorServer.ID,
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

enum SnapONetRecord: Sendable {
  case hello(SnapONetHelloRecord)
  case replayComplete(SnapONetReplayCompleteRecord)
  case lifecycle(SnapONetLifecycleRecord)
  case requestWillBeSent(SnapONetRequestWillBeSentRecord)
  case responseReceived(SnapONetResponseReceivedRecord)
  case requestFailed(SnapONetRequestFailedRecord)
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

struct SnapONetRequestWillBeSentRecord: SnapONetPerRequestRecord, Hashable {
  let schemaVersion: String
  let id: String
  let tWallMs: Int64
  let tMonoNs: Int64
  let method: String
  let url: String
  let headers: [String: String]
  let bodyPreview: String?
  let bodySize: Int64?

  init(
    schemaVersion: String = SnapONetRecordDecoder.defaultSchemaVersion,
    id: String,
    tWallMs: Int64,
    tMonoNs: Int64,
    method: String,
    url: String,
    headers: [String: String] = [:],
    bodyPreview: String? = nil,
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
    headers = try container.decodeIfPresent([String: String].self, forKey: .headers) ?? [:]
    bodyPreview = try container.decodeIfPresent(String.self, forKey: .bodyPreview)
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
    case bodySize
  }
}

struct SnapONetResponseReceivedRecord: SnapONetPerRequestRecord, Hashable {
  let schemaVersion: String
  let id: String
  let tWallMs: Int64
  let tMonoNs: Int64
  let code: Int
  let headers: [String: String]
  let bodyPreview: String?
  let bodySize: Int64?
  let timings: SnapONetTimings

  init(
    schemaVersion: String = SnapONetRecordDecoder.defaultSchemaVersion,
    id: String,
    tWallMs: Int64,
    tMonoNs: Int64,
    code: Int,
    headers: [String: String] = [:],
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
    headers = try container.decodeIfPresent([String: String].self, forKey: .headers) ?? [:]
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

enum SnapONetRecordDecoder {
  static let defaultSchemaVersion = "1.0"
  static let defaultCapabilities = ["network"]
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
    case "RequestWillBeSent":
      let record = try decoder.decode(SnapONetRequestWillBeSentRecord.self, from: data)
      return .requestWillBeSent(record)
    case "ResponseReceived":
      let record = try decoder.decode(SnapONetResponseReceivedRecord.self, from: data)
      return .responseReceived(record)
    case "RequestFailed":
      let record = try decoder.decode(SnapONetRequestFailedRecord.self, from: data)
      return .requestFailed(record)
    default:
      let raw = String(data: data, encoding: .utf8) ?? "<unparseable>"
      return .unknown(type: discriminator.type, rawJSON: raw)
    }
  }
}
