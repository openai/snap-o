import Foundation
import SnapODeviceClient

enum AppInspectorKind: String, Codable {
  case network
  case tweaks
}

struct InspectorServerReference: Codable, Hashable {
  let deviceId: String
  let socketName: String
}

struct AppInspectorOption: Codable, Identifiable {
  let kind: AppInspectorKind
  let server: InspectorServerReference
  let protocolVersion: Int?

  var id: String {
    "\(kind.rawValue):\(server.deviceId):\(server.socketName)"
  }
}

struct InspectableApp: Codable, Identifiable {
  let id: String
  let name: String
  let packageName: String
  let deviceId: String
  let deviceDisplayTitle: String
  let appIconBase64: String?
  let inspectors: [AppInspectorOption]
}

struct SelectedAppInspector: Codable {
  let appId: String
  let kind: AppInspectorKind
  let server: InspectorServerReference
  let protocolVersion: Int?
}

enum TweakValue: Codable {
  case bool(Bool)
  case int(Int)
  case double(Double)
  case string(String)

  init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if let value = try? container.decode(Bool.self) {
      self = .bool(value)
    } else if let value = try? container.decode(Int.self) {
      self = .int(value)
    } else if let value = try? container.decode(Double.self) {
      self = .double(value)
    } else {
      self = try .string(container.decode(String.self))
    }
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .bool(let value):
      try container.encode(value)
    case .int(let value):
      try container.encode(value)
    case .double(let value):
      try container.encode(value)
    case .string(let value):
      try container.encode(value)
    }
  }
}

struct TweakDescriptor: Codable {
  let name: String
  let type: String
  let `default`: TweakValue?
  let value: TweakValue?
  let modified: Bool?
  let min: TweakValue?
  let max: TweakValue?
  let step: TweakValue?
  let options: [String]?
  let conflicted: Bool?
}

struct TweakList: Codable {
  let tweaks: [TweakDescriptor]
}

struct TweakStreamEvent: Codable {
  let streamId: String
  let server: InspectorServerReference
  let tweaks: [TweakDescriptor]
}

struct TweaksInspectorNativeState: Codable {
  let server: InspectorServerReference
  let hasResettableTweaks: Bool
}

struct TweakUpdate: Codable {
  let name: String
  let value: TweakValue
  let modified: Bool?
}

struct TweakUpdateError: Codable {
  let name: String
  let error: String
}

struct TweakUpdates: Codable {
  let tweaks: [TweakUpdate]
  let errors: [TweakUpdateError]?
}

struct TweakPatch: Codable {
  let values: [String: TweakValue?]
}

struct UpdateTweaksInput: Codable {
  let server: InspectorServerReference
  let values: [String: TweakValue?]
}

struct InvokeTweakActionInput: Codable {
  let server: InspectorServerReference
  let name: String
}

struct TweakAction: Codable {
  let name: String
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
  let instanceId: String?
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
  let serverInstanceId: String?
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
  let serverInstanceId: String?
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
  case tweaks(TweakStreamEvent)
}

extension NetworkInspectorServer: Sendable {}
extension NetworkInspectorNativeState: Sendable {}
extension NetworkLoadBodiesInput: Sendable {}
extension NetworkRequestBodies: Sendable {}
extension NetworkStreamStarted: Sendable {}
extension NetworkStreamEvent: Sendable {}
extension NetworkStreamStatus: Sendable {}
extension InspectorServerReference: Sendable {}
extension TweakValue: Sendable {}
extension TweakDescriptor: Sendable {}
extension TweakList: Sendable {}
extension TweakStreamEvent: Sendable {}
extension NetworkSaveFileInput: Sendable {}
extension NetworkSaveFileResult: Sendable {}
extension NetworkInspectorOutput: Sendable {}

enum NetworkInspectorError: LocalizedError {
  case invalidBridgeMessage
  case serverNotConnected(NetworkServerReference)
  case tweakRequestFailed(statusCode: Int, message: String)

  var errorDescription: String? {
    switch self {
    case .invalidBridgeMessage:
      "Invalid Network Inspector bridge message."
    case .serverNotConnected(let server):
      "Snap-O server is not connected: \(server.deviceId)/\(server.socketName)"
    case .tweakRequestFailed(_, let message):
      message
    }
  }
}
