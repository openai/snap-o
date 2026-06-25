import Foundation
import SnapODeviceClient

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
}

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

enum NetworkInspectorError: LocalizedError {
  case invalidBridgeMessage
  case serverNotConnected(NetworkServerReference)

  var errorDescription: String? {
    switch self {
    case .invalidBridgeMessage:
      "Invalid Network Inspector bridge message."
    case .serverNotConnected(let server):
      "Snap-O server is not connected: \(server.deviceId)/\(server.socketName)"
    }
  }
}
