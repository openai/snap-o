import Foundation

struct AppToolOption: Equatable, Codable, Identifiable {
  let kind: PluginID
  let server: PluginServerReference
  let protocolVersion: Int?
  let isConnected: Bool
  var name = ""
  var iconBase64: String?
  var compatibility: PluginCompatibility = .unknown
  var displayName: String {
    name.isEmpty ? kind.rawValue : name
  }

  var id: String {
    "\(kind.rawValue):\(server.deviceId):\(server.socketName)"
  }
}

enum PluginCompatibility: Equatable, Codable {
  case unknown
  case supported
  case legacy(protocolVersion: Int)
  case missingDescriptor
  case invalidDescriptor
  case missingFrontend(protocolVersion: Int)
  case hostAPI(version: Int)
  case metadataUnavailable

  var isUnsupported: Bool {
    switch self {
    case .legacy, .missingDescriptor, .invalidDescriptor, .missingFrontend, .hostAPI: true
    case .unknown, .supported, .metadataUnavailable: false
    }
  }

  func title(for kind: PluginID?) -> String? {
    let toolName = kind.map { $0.rawValue.prefix(1).uppercased() + $0.rawValue.dropFirst() } ?? "tool"
    return switch self {
    case .unknown, .supported: nil
    case .metadataUnavailable: "Tool unavailable"
    case .legacy, .missingDescriptor, .missingFrontend, .hostAPI: "Unsupported \(toolName) version"
    default: "Unsupported tool"
    }
  }

  var explanation: String? {
    switch self {
    case .unknown, .supported: nil
    case .legacy:
      "This app uses an older Snap-O library that this version of Snap-O no longer supports." + Self.libraryGuidance
    case .missingDescriptor:
      "This app appears to use an older Snap-O library that this version of Snap-O no longer supports." + Self.libraryGuidance
    case .invalidDescriptor:
      "This app declares invalid tool metadata. Fix the tool’s configuration and rebuild the app."
    case .missingFrontend:
      "This app’s Snap-O library does not include a tool interface for this version of Snap-O." + Self.libraryGuidance
    case .hostAPI(let version):
      version > 1
        ? "This tool requires host API \(version). This version of Snap-O supports host API 1. Update Snap-O to open it."
        : "This tool uses unsupported host API \(version)." + Self.libraryGuidance
    case .metadataUnavailable:
      "Snap-O could not reach this tool or check its library version. Open the app on your device. Snap-O will retry automatically."
    }
  }

  private static let libraryGuidance =
    "\n\nUpdate the app’s Snap-O libraries and rebuild it, or use an older version of Snap-O that supports this app."

  var versionDetail: String? {
    switch self {
    case .legacy(let version), .missingFrontend(let version): "Tool protocol \(version)"
    default: nil
    }
  }
}

struct InspectableApp: Equatable, Codable, Identifiable {
  let id: String
  let pid: Int?
  let deviceId: String
  let deviceDisplayTitle: String
  var tools: [AppToolOption]
  var metadata: PluginMetadata.Process?

  var name: String {
    metadata?.name ?? processName ?? packageName ?? pid.map { "Process \($0)" }
      ?? tools.first?.server.socketName ?? id
  }

  var packageName: String? {
    metadata?.packageName
  }

  var processName: String? {
    metadata?.processName
  }

  var androidUserId: Int? {
    metadata?.verifiedIdentity?.androidUserId
  }

  var appIconBase64: String? {
    metadata?.iconBase64
  }
}

struct PluginDiscoverySnapshot {
  let apps: [InspectableApp]
  var revision: UInt64?
}

struct OpenAppInput: Codable {
  let deviceId: String
  let packageName: String
  let androidUserId: Int
}

struct SelectedAppTool: Equatable, Codable {
  let appId: String
  let kind: PluginID
  let server: PluginServerReference
  let protocolVersion: Int?
}

struct AppToolState: Equatable, Codable {
  let apps: [InspectableApp]
  let selection: SelectedAppTool?
  let displayed: [PluginID: SelectedAppTool]
  let selectedApp: InspectableApp?
  let replacementApp: InspectableApp?
  let preferredKind: PluginID?
  let isRestoring: Bool
}

struct ToolSaveFileInput: Codable {
  let defaultPath: String
  let data: String
  let mimeType: String?
  let encoding: String?
}

struct ToolSaveFileResult: Codable {
  let saved: Bool
  let path: String?
}

extension ToolSaveFileInput: Sendable {}
extension ToolSaveFileResult: Sendable {}

enum PluginError: LocalizedError {
  case invalidBridgeMessage
  case frontendUnavailable
  case serverNotConnected(PluginServerReference)
  case requestFailed(statusCode: Int, message: String)

  var errorDescription: String? {
    switch self {
    case .invalidBridgeMessage:
      "Invalid tool bridge message."
    case .frontendUnavailable:
      "This tool has no compatible frontend. Update its Android library or select a development server."
    case .serverNotConnected(let server):
      "Snap-O server is not connected: \(server.deviceId)/\(server.socketName)"
    case .requestFailed(_, let message):
      message
    }
  }
}

struct PluginConnectionState: Encodable {
  var revision = 0
  var baseURL: String?
  var connected = false
  var metadata: PluginMetadata.Process?
  var tool: PluginDescriptor?

  private enum CodingKeys: String, CodingKey {
    case revision, baseURL, connected, manifest
    case tool = "inspector"
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(revision, forKey: .revision)
    try container.encodeIfPresent(baseURL, forKey: .baseURL)
    try container.encode(connected, forKey: .connected)
    try container.encodeIfPresent(metadata.flatMap(FrontendManifest.init), forKey: .manifest)
    try container.encodeIfPresent(tool, forKey: .tool)
  }

  /// Preserve the frontend contract without exposing discovery response types to the app model.
  private struct FrontendManifest: Encodable {
    struct Package: Encodable {
      let packageName: String
      let name: String
      let revision: String
      let iconBase64: String?
      let tools: [PluginDescriptor]

      private enum CodingKeys: String, CodingKey {
        case packageName, name, revision, iconBase64
        case tools = "inspectors"
      }
    }

    let version = 1
    let pid: Int
    let processName: String?
    let androidUserId: Int
    let processIdentity: String
    let app: Package

    init?(metadata: PluginMetadata.Process) {
      guard let identity = metadata.verifiedIdentity else { return nil }
      pid = identity.pid
      processName = identity.processName ?? metadata.processName
      androidUserId = identity.androidUserId
      processIdentity = identity.processIdentity
      app = Package(
        packageName: identity.packageName, name: metadata.name ?? identity.packageName, revision: identity.revision,
        iconBase64: metadata.iconBase64, tools: metadata.tools
      )
    }
  }
}

struct ToolToolbar: Decodable {
  let revision: Int
  var actions: [ToolToolbarAction]

  func validate() throws {
    guard (1 ... Int(UInt32.max)).contains(revision), actions.count <= 11,
          actions.count(where: { $0.position == .start }) <= 3,
          Set(actions.map(\.id)).count == actions.count,
          !actions.contains(where: { $0.type == .search && $0.position == .end }),
          actions.count(where: { $0.type == .search }) <= 1,
          actions
          .allSatisfy({
            !$0.id.isEmpty && !$0.label.isEmpty && $0.id.count <= 100 && $0.label.count <= 200 && ($0.value?.utf8.count ?? 0) <= 4096
              && (0 ... Int(UInt32.max)).contains($0.inputRevision ?? 0)
              && ($0.type != .button || $0.icon != nil) }) else {
      throw PluginError.invalidBridgeMessage
    }
  }
}

struct ToolToolbarAction: Decodable, Identifiable {
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

struct ToolToolbarEvent: Encodable {
  let revision: Int
  let id: String
  var value: String?
  var inputRevision: Int?
}
