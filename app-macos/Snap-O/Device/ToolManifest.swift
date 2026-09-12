import Foundation

public struct ToolDescriptor: Codable, Sendable, Equatable {
  public let id: ToolID
  public let name: String
  public let protocolVersion: Int
  public let iconBase64: String?
  public let frontend: ToolFrontend?
}

public struct ToolFrontend: Codable, Sendable, Equatable {
  public let assetPath: String
  public let hostApiVersion: Int
}

public struct ToolPackageMetadata: Codable, Sendable, Equatable {
  public let packageName: String
  public let name: String
  public let revision: String
  public let iconBase64: String?
  public let tools: [ToolDescriptor]
  public let errors: [ToolDescriptorError]?

  /// Keep the discovery format compatible with installed Android libraries.
  private enum CodingKeys: String, CodingKey {
    case packageName, name, revision, iconBase64, errors
    case tools = "inspectors"
  }
}

public struct ToolDescriptorError: Codable, Sendable, Equatable {
  public let key: String
  public let error: String
}

public struct ToolProcessMetadata: Codable, Sendable, Equatable {
  public let version: Int
  public let pid: Int
  public let processName: String?
  public let androidUserId: Int?
  public let processIdentity: String?
  public let app: ToolPackageMetadata?
  public let error: String?
}

public struct ToolProcessIdentity: Codable, Sendable, Equatable {
  public let pid: Int
  public let processName: String?
  public let androidUserId: Int
  public let processIdentity: String
  public let packageName: String
  public let revision: String

  public init?(metadata: ToolProcessMetadata) {
    guard metadata.version == 1, metadata.pid > 0,
          let identity = metadata.processIdentity, !identity.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          let user = metadata.androidUserId, user >= 0, let app = metadata.app,
          !app.packageName.isEmpty, !app.revision.isEmpty else { return nil }
    pid = metadata.pid
    processName = metadata.processName
    androidUserId = user
    processIdentity = identity
    packageName = app.packageName
    revision = app.revision
  }
}

enum ToolManifestReader {
  static func command(helper: Data, socketNames: [String], frontendRequest: Data? = nil) throws -> String {
    guard !socketNames.isEmpty, socketNames.count <= 64,
          socketNames.allSatisfy({ $0.range(
            of: #"^snapo_[a-z][a-z0-9.-]{0,99}_[1-9][0-9]{0,9}$"#,
            options: .regularExpression
          ) != nil }),
          helper.count <= 32768, frontendRequest == nil || socketNames.count == 1,
          (frontendRequest?.count ?? 0) <= 8192 else {
      throw ADBError.parseFailure("invalid tool discovery request")
    }
    // Keep uploads and execution separate from concurrent desktop or CLI readers.
    return """
    directory=$(mktemp -d /data/local/tmp/snapo-discovery.XXXXXX) || exit 1
    trap 'rm -f "$directory/reader.jar"; rmdir "$directory"' EXIT
    (umask 077; printf '%s' '\(helper.base64EncodedString())' | base64 -d > "$directory/reader.jar") &&
      chmod 444 "$directory/reader.jar" || exit 1
      CLASSPATH="$directory/reader.jar" app_process / com.openai.snapo.discovery.\(frontendRequest == nil ? "Main" :
      "FrontendMain") \(socketNames.joined(separator: " ")) \(frontendRequest?.base64EncodedString() ?? "") 2>/dev/null
    """
  }

  static func decode(_ data: Data) throws -> [ToolProcessMetadata] {
    try data.split(separator: 10).map { line in
      guard line.count <= 1_048_576 else { throw ADBError.parseFailure("tool metadata is too large") }
      let value = try JSONDecoder().decode(ToolProcessMetadata.self, from: Data(line))
      guard value.version == 1 else { throw ADBError.parseFailure("unsupported tool discovery format") }
      if value.app != nil, value.processIdentity?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
        throw ADBError.parseFailure("tool metadata is missing process identity")
      }
      return value
    }
  }
}
