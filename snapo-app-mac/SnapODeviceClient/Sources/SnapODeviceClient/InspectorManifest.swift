import Foundation

public struct InspectorDescriptor: Codable, Sendable, Equatable {
  public let id: InspectorID
  public let name: String
  public let protocolVersion: Int
  public let iconBase64: String?
  public let frontend: InspectorFrontend?
}

public struct InspectorFrontend: Codable, Sendable, Equatable {
  public let assetPath: String
  public let hostApiVersion: Int
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
  static func command(helper: Data, socketNames: [String], frontendRequest: Data? = nil) throws -> String {
    guard !socketNames.isEmpty, socketNames.count <= 64,
          socketNames.allSatisfy({ $0.range(
            of: #"^snapo_[a-z][a-z0-9.-]{0,99}_[1-9][0-9]{0,9}$"#,
            options: .regularExpression
          ) != nil }),
          helper.count <= 32768, frontendRequest == nil || socketNames.count == 1,
          (frontendRequest?.count ?? 0) <= 8192 else {
      throw ADBError.parseFailure("invalid inspector discovery request")
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
