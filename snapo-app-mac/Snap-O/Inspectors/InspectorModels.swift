import Foundation
import SnapODeviceClient

typealias InspectorServerReference = NetworkServerReference

struct AppInspectorOption: Equatable, Codable, Identifiable {
  let kind: InspectorID
  let server: InspectorServerReference
  let protocolVersion: Int?
  var name = ""
  var icon = "square"
  var displayName: String {
    name.isEmpty ? kind.rawValue : name
  }

  var id: String {
    "\(kind.rawValue):\(server.deviceId):\(server.socketName)"
  }
}

struct InspectableApp: Equatable, Codable, Identifiable {
  let id: String
  let name: String
  let packageName: String?
  let processName: String?
  let androidUserId: Int?
  let deviceId: String
  let deviceDisplayTitle: String
  let appIconBase64: String?
  let inspectors: [AppInspectorOption]
}

struct InspectorDiscoverySnapshot {
  let apps: [InspectableApp]
}

struct OpenAppInput: Codable {
  let deviceId: String
  let packageName: String
  let androidUserId: Int
}

struct SelectedAppInspector: Equatable, Codable {
  let appId: String
  let kind: InspectorID
  let server: InspectorServerReference
  let protocolVersion: Int?
}

struct AppInspectorState: Equatable, Codable {
  let apps: [InspectableApp]
  let selection: SelectedAppInspector?
  let displayed: [InspectorID: SelectedAppInspector]
  let selectedApp: InspectableApp?
  let replacementApp: InspectableApp?
  let preferredKind: InspectorID?
  let isRestoring: Bool
}

struct InspectorSaveFileInput: Codable {
  let defaultPath: String
  let data: String
  let mimeType: String?
  let encoding: String?
}

struct InspectorSaveFileResult: Codable {
  let saved: Bool
  let path: String?
}

extension InspectorSaveFileInput: Sendable {}
extension InspectorSaveFileResult: Sendable {}

enum InspectorError: LocalizedError {
  case invalidBridgeMessage
  case serverNotConnected(NetworkServerReference)
  case requestFailed(statusCode: Int, message: String)

  var errorDescription: String? {
    switch self {
    case .invalidBridgeMessage:
      "Invalid inspector bridge message."
    case .serverNotConnected(let server):
      "Snap-O server is not connected: \(server.deviceId)/\(server.socketName)"
    case .requestFailed(_, let message):
      message
    }
  }
}

struct InspectorConnectionState: Encodable {
  var revision = 0
  var baseURL: String?
  var connected = false
}

struct InspectorToolbar: Decodable {
  let revision: Int
  var actions: [InspectorToolbarAction]

  func validate() throws {
    guard revision > 0,
          actions.count(where: { $0.position == .start }) <= 3,
          Set(actions.map(\.id)).count == actions.count,
          !actions.contains(where: { $0.type == .search && $0.position == .end }),
          actions.count(where: { $0.type == .search }) <= 1,
          actions.allSatisfy({ !$0.id.isEmpty && !$0.label.isEmpty && $0.id.count <= 100 && $0.label.count <= 200
              && ($0.type != .button || $0.icon != nil) }) else {
      throw InspectorError.invalidBridgeMessage
    }
  }
}

struct InspectorToolbarAction: Decodable, Identifiable {
  enum Kind: String, Decodable { case button, search }
  enum Placement: String, Decodable { case start, end }
  enum Icon: String, Decodable {
    case clear, sortAscending, sortDescending, search, export, reset
    var symbol: String {
      switch self {
      case .clear: "trash"
      case .sortAscending: "arrow.down"
      case .sortDescending: "arrow.up"
      case .search: "magnifyingglass"
      case .export: "square.and.arrow.up"
      case .reset: "arrow.counterclockwise"
      }
    }
  }

  let placement: Placement?
  var position: Placement {
    placement ?? .start
  }

  let type: Kind
  let id: String
  let icon: Icon?
  let label: String
  let enabled: Bool?
  var value: String?
  var inputRevision: Int?
}

struct InspectorToolbarEvent: Encodable {
  let revision: Int
  let id: String
  var value: String?
  var inputRevision: Int?
}
