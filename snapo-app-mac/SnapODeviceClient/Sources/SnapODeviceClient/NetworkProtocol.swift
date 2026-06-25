import Foundation

public enum SnapONetworkProtocol {
  public static let clientHello = "HelloSnapO"
  public static let supportedVersion = 1

  public enum Method {
    public static let appInfo = "SnapO.appInfo"
    public static let replayComplete = "SnapO.replayComplete"
    public static let startStream = "SnapO.startStream"
    public static let stopStream = "SnapO.stopStream"
    public static let getRequestPostData = "Network.getRequestPostData"
    public static let getResponseBody = "Network.getResponseBody"
  }
}

public enum JSONValue: Codable, Sendable, Equatable {
  case array([JSONValue])
  case bool(Bool)
  case null
  case number(Double)
  case object([String: JSONValue])
  case string(String)

  public init(from decoder: Decoder) throws {
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

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .array(let value): try container.encode(value)
    case .bool(let value): try container.encode(value)
    case .null: try container.encodeNil()
    case .number(let value): try container.encode(value)
    case .object(let value): try container.encode(value)
    case .string(let value): try container.encode(value)
    }
  }

  public var stringValue: String? {
    guard case .string(let value) = self else { return nil }
    return value
  }

  public var boolValue: Bool? {
    guard case .bool(let value) = self else { return nil }
    return value
  }
}

public struct NetworkCDPError: Codable, Sendable, Equatable {
  public let code: Int
  public let message: String
  public let data: JSONValue?

  public init(code: Int, message: String, data: JSONValue? = nil) {
    self.code = code
    self.message = message
    self.data = data
  }
}

public struct NetworkCDPMessage: Codable, Sendable, Equatable {
  public let id: Int?
  public let method: String?
  public var params: [String: JSONValue]?
  public var result: [String: JSONValue]?
  public let error: NetworkCDPError?
  public let snapoSequence: UInt64?

  public init(
    id: Int? = nil,
    method: String? = nil,
    params: [String: JSONValue]? = nil,
    result: [String: JSONValue]? = nil,
    error: NetworkCDPError? = nil,
    snapoSequence: UInt64? = nil
  ) {
    self.id = id
    self.method = method
    self.params = params
    self.result = result
    self.error = error
    self.snapoSequence = snapoSequence
  }
}

public struct NetworkAppIcon: Codable, Sendable, Equatable {
  public let width: Int
  public let height: Int
  public let format: String?
  public let base64Data: String

  public init(width: Int, height: Int, format: String?, base64Data: String) {
    self.width = width
    self.height = height
    self.format = format
    self.base64Data = base64Data
  }
}

public struct NetworkAppInfo: Codable, Sendable, Equatable {
  public let protocolVersion: Int
  public let packageName: String
  public let processName: String
  public let pid: Int
  public let serverStartWallMs: Int64
  public let serverStartMonoNs: Int64
  public let mode: String
  public let icon: NetworkAppIcon?

  public init(
    protocolVersion: Int,
    packageName: String,
    processName: String,
    pid: Int,
    serverStartWallMs: Int64,
    serverStartMonoNs: Int64,
    mode: String,
    icon: NetworkAppIcon?
  ) {
    self.protocolVersion = protocolVersion
    self.packageName = packageName
    self.processName = processName
    self.pid = pid
    self.serverStartWallMs = serverStartWallMs
    self.serverStartMonoNs = serverStartMonoNs
    self.mode = mode
    self.icon = icon
  }
}

public struct NetworkServerReference: Codable, Hashable, Sendable {
  public let deviceId: String
  public let socketName: String

  public init(deviceId: String, socketName: String) {
    self.deviceId = deviceId
    self.socketName = socketName
  }

  public var key: String {
    "\(deviceId)\0\(socketName)"
  }

  public var identifier: String {
    "\(deviceId)/\(socketName)"
  }
}

public enum NetworkServerRecord: Sendable, Equatable {
  case appInfo(NetworkAppInfo)
  case network(NetworkCDPMessage)
  case replayComplete(watermark: UInt64?)
  case unknown
}
