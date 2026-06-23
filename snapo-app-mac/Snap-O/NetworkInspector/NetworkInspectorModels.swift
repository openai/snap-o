import Foundation

enum JSONValue: Codable {
  case array([JSONValue])
  case bool(Bool)
  case null
  case number(Double)
  case object([String: JSONValue])
  case string(String)

  init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self = .null
    } else if let value = try? container.decode(Bool.self) {
      self = .bool(value)
    } else if let value = try? container.decode(Double.self) {
      self = .number(value)
    } else if let value = try? container.decode(String.self) {
      self = .string(value)
    } else if let value = try? container.decode([JSONValue].self) {
      self = .array(value)
    } else {
      self = try .object(container.decode([String: JSONValue].self))
    }
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .array(let value):
      try container.encode(value)
    case .bool(let value):
      try container.encode(value)
    case .null:
      try container.encodeNil()
    case .number(let value):
      try container.encode(value)
    case .object(let value):
      try container.encode(value)
    case .string(let value):
      try container.encode(value)
    }
  }

  var boolValue: Bool? {
    guard case .bool(let value) = self else { return nil }
    return value
  }

  var stringValue: String? {
    guard case .string(let value) = self else { return nil }
    return value
  }
}

struct NetworkCDPError: Codable {
  let code: Int
  let message: String
  let data: JSONValue?
}

struct NetworkCDPMessage: Codable {
  var id: Int?
  var method: String?
  var params: [String: JSONValue]?
  var result: [String: JSONValue]?
  var error: NetworkCDPError?

  init(
    id: Int? = nil,
    method: String? = nil,
    params: [String: JSONValue]? = nil,
    result: [String: JSONValue]? = nil,
    error: NetworkCDPError? = nil
  ) {
    self.id = id
    self.method = method
    self.params = params
    self.result = result
    self.error = error
  }
}

struct NetworkAppIcon: Codable {
  let width: Int
  let height: Int
  let format: String?
  let base64Data: String
}

struct NetworkAppInfo: Codable {
  let protocolVersion: Int
  let packageName: String
  let processName: String
  let pid: Int
  let serverStartWallMs: Double
  let serverStartMonoNs: Double
  let mode: String
  let icon: NetworkAppIcon?
}

struct NetworkServerReference: Codable, Hashable {
  let deviceId: String
  let socketName: String

  var key: String {
    "\(deviceId)\0\(socketName)"
  }
}

struct NetworkInspectorServer: Codable {
  let server: String
  let deviceId: String
  let socketName: String
  let deviceDisplayTitle: String
  let displayName: String
  let isConnected: Bool
  let hasAppInfo: Bool
  let pid: Int?
  let protocolVersion: Int?
  let isProtocolNewerThanSupported: Bool
  let isProtocolOlderThanSupported: Bool
  let appIconBase64: String?
  let packageName: String?
  let appName: String?
}

struct NetworkInspectorNativeState: Codable {
  let servers: [NetworkInspectorServer]
  let selectedServer: NetworkServerReference?
  let searchText: String
  let sortNewestFirst: Bool
  let hasClearableItems: Bool
  let selectedRecordKind: String?
  let hasVisibleRecords: Bool
}

struct NetworkLoadBodiesInput: Codable {
  let deviceId: String
  let socketName: String
  let requestId: String
  let includeRequestBody: Bool?
  let includeResponseBody: Bool?
}

struct NetworkRequestBodies: Codable {
  let requestId: String
  let requestBody: String?
  let responseBody: String?
  let responseBodyBase64Encoded: Bool?
}

struct NetworkStreamStarted: Codable {
  let streamId: String
}

struct NetworkStreamEvent: Codable {
  let streamId: String
  let server: NetworkServerReference
  let message: NetworkCDPMessage
}

struct NetworkStreamStatus: Codable {
  let streamId: String
  let state: String
  let message: String?
  let code: Int?
  let signal: String?
}

struct NetworkSaveFileInput: Codable {
  let defaultPath: String
  let data: String
  let mimeType: String?
  let encoding: String?
  let directoryKind: NetworkSaveDirectoryKind?
}

enum NetworkSaveDirectoryKind: String, Codable {
  case har
}

struct NetworkSaveFileResult: Codable {
  let saved: Bool
  let path: String?
}

enum NetworkInspectorOutput {
  case event(NetworkStreamEvent)
  case status(NetworkStreamStatus)
}

enum NetworkServerRecord {
  case appInfo(NetworkAppInfo)
  case network(NetworkCDPMessage)
  case replayComplete
  case unknown
}

extension JSONValue: Sendable {}
extension NetworkCDPError: Sendable {}
extension NetworkCDPMessage: Sendable {}
extension NetworkAppIcon: Sendable {}
extension NetworkAppInfo: Sendable {}
extension NetworkServerReference: Sendable {}
extension NetworkInspectorServer: Sendable {}
extension NetworkInspectorNativeState: Sendable {}
extension NetworkLoadBodiesInput: Sendable {}
extension NetworkRequestBodies: Sendable {}
extension NetworkStreamStarted: Sendable {}
extension NetworkStreamEvent: Sendable {}
extension NetworkStreamStatus: Sendable {}
extension NetworkSaveFileInput: Sendable {}
extension NetworkSaveFileResult: Sendable {}
extension NetworkInspectorOutput: Sendable {}
extension NetworkServerRecord: Sendable {}

enum NetworkInspectorError: LocalizedError {
  case invalidBridgeMessage
  case serverDisconnected
  case serverNotConnected(NetworkServerReference)
  case timedOut(String)

  var errorDescription: String? {
    switch self {
    case .invalidBridgeMessage:
      "Invalid Network Inspector bridge message."
    case .serverDisconnected:
      "The Network Inspector server disconnected."
    case .serverNotConnected(let server):
      "Snap-O server is not connected: \(server.deviceId)/\(server.socketName)"
    case .timedOut(let method):
      "Timed out waiting for \(method)."
    }
  }
}
