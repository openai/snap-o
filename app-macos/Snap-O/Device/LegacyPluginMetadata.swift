import Foundation

/// Display evidence only. Legacy metadata never authorizes a frontend or tool requests.
public struct LegacyPluginMetadata: Sendable, Equatable {
  public let packageName: String
  public let name: String?
  public let processName: String?
  public let protocolVersion: Int
}

enum LegacyPluginReader {
  static let maximumBytes = 1_048_576

  static func requests(kind: ToolID) -> [String] {
    switch kind.rawValue {
    case "network": ["HelloSnapO\n", httpRequest("/.snap-o/info")]
    case "tweaks": [httpRequest("/.snap-o/info"), httpRequest("/app")]
    default: []
    }
  }

  private static func httpRequest(_ path: String) -> String {
    "GET \(path) HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"
  }

  static func payload(_ bytes: Data, http: Bool, ended: Bool = false) throws -> Data? {
    guard bytes.count <= maximumBytes else { throw ADBError.parseFailure("legacy metadata is too large") }
    if !http {
      return bytes.firstIndex(of: 10).map { Data(bytes[..<$0]) }
    }
    guard let separator = bytes.range(of: Data("\r\n\r\n".utf8)) else {
      guard bytes.count <= 8192 else { throw ADBError.parseFailure("legacy HTTP headers are too large") }
      return nil
    }
    guard separator.lowerBound <= 8192,
          let header = String(data: bytes[..<separator.lowerBound], encoding: .utf8) else {
      throw ADBError.parseFailure("invalid legacy HTTP response")
    }
    let lines = header.components(separatedBy: "\r\n")
    guard let status = lines.first?.split(separator: " "), status.count >= 2,
          ["HTTP/1.0", "HTTP/1.1"].contains(String(status[0])), status[1] == "200" else {
      throw ADBError.parseFailure("legacy metadata endpoint is unavailable")
    }
    var length: Int?
    for line in lines.dropFirst() {
      let parts = line.split(separator: ":", maxSplits: 1)
      guard parts.count == 2 else { throw ADBError.parseFailure("invalid legacy HTTP header") }
      let key = parts[0].lowercased()
      guard key != "transfer-encoding" else { throw ADBError.parseFailure("unsupported legacy HTTP encoding") }
      if key == "content-length" {
        guard length == nil, let value = Int(parts[1].trimmingCharacters(in: .whitespaces)),
              (0 ... maximumBytes).contains(value) else { throw ADBError.parseFailure("invalid legacy metadata length") }
        length = value
      }
    }
    let body = Data(bytes[separator.upperBound...])
    if let length {
      return body.count >= length ? Data(body.prefix(length)) : nil
    }
    return ended ? body : nil
  }

  static func decode(_ data: Data, kind: ToolID, pid: Int, http: Bool) throws -> LegacyPluginMetadata? {
    struct Metadata: Decodable {
      let packageName: String
      let name: String?
      let processName: String?
      let pid: Int?
      let protocolVersion: Int
    }
    struct Envelope: Decodable {
      let method: String
      let params: Metadata
    }
    guard data.count <= maximumBytes else { return nil }
    let value: Metadata
    if http {
      value = try JSONDecoder().decode(Metadata.self, from: data)
    } else {
      let envelope = try JSONDecoder().decode(Envelope.self, from: data)
      guard envelope.method == "SnapO.appInfo" else { return nil }
      value = envelope.params
    }
    guard !value.packageName.isEmpty, value.packageName.count <= 255,
          value.pid == nil || value.pid == pid else { return nil }
    switch kind.rawValue {
    case "network":
      guard value.pid == pid, value.processName?.isEmpty == false,
            value.protocolVersion == (http ? 2 : 1) else { return nil }
    case "tweaks":
      guard http, (1 ... 6).contains(value.protocolVersion), value.name?.isEmpty == false else { return nil }
    default: return nil
    }
    return LegacyPluginMetadata(
      packageName: value.packageName, name: value.name, processName: value.processName,
      protocolVersion: value.protocolVersion
    )
  }
}
