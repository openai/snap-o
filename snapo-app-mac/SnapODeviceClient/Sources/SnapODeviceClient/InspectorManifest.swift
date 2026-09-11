import Foundation

public struct InspectorDescriptor: Codable, Sendable, Equatable {
  public let id: InspectorID
  public let name: String
  public let protocolVersion: Int
  public let iconBase64: String?
}

public struct InspectorPackageMetadata: Codable, Sendable, Equatable {
  public let packageName: String
  public let name: String
  public let revision: String
  public let iconBase64: String?
  public let inspectors: [InspectorDescriptor]
}

public struct InspectorProcessMetadata: Codable, Sendable, Equatable {
  public let version: Int
  public let pid: Int
  public let processName: String?
  public let androidUserId: Int?
  public let processIdentity: String?
  public let app: InspectorPackageMetadata?
  public let error: String?
}

enum InspectorManifestReader {
  static func command(helper: Data, socketNames: [String]) throws -> String {
    guard !socketNames.isEmpty, socketNames.count <= 64,
          socketNames.allSatisfy({ $0.range(
            of: #"^snapo_[a-z][a-z0-9.-]{0,99}_[1-9][0-9]{0,9}$"#,
            options: .regularExpression
          ) != nil }),
          helper.count <= 32768 else {
      throw ADBError.parseFailure("invalid inspector discovery request")
    }
    let path = "/data/local/tmp/snapo-discovery.jar"
    // Refresh before each metadata read; a fixed path never accumulates old versions.
    return """
    temp='\(path).tmp'
    trap 'rm -f "$temp"' EXIT
    rm -f "$temp" || exit 1
    (umask 077; printf '%s' '\(helper.base64EncodedString())' | base64 -d > "$temp") &&
      chmod 444 "$temp" && mv -f "$temp" '\(path)' || exit 1
    CLASSPATH='\(path)' app_process / com.openai.snapo.discovery.Main \(socketNames.joined(separator: " ")) 2>/dev/null
    """
  }

  static func decode(_ data: Data) throws -> [InspectorProcessMetadata] {
    try data.split(separator: 10).map { line in
      guard line.count <= 1_048_576 else { throw ADBError.parseFailure("inspector metadata is too large") }
      let value = try JSONDecoder().decode(InspectorProcessMetadata.self, from: Data(line))
      guard value.version == 1 else { throw ADBError.parseFailure("unsupported inspector discovery format") }
      if value.app != nil, value.processIdentity?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
        throw ADBError.parseFailure("inspector metadata is missing process identity")
      }
      return value
    }
  }
}
