import Foundation
import ZIPFoundation

public struct PluginFrontendBundle: Sendable {
  public let entryPoint = "index.html"
  public let files: [String: Data]

  public var byteCount: Int {
    files.values.reduce(0) { $0 + $1.count }
  }

  public init(archive data: Data) throws {
    let maximumBytes = 16 * 1024 * 1024
    guard data.count <= maximumBytes else { throw ADBError.parseFailure("tool archive is too large") }
    let archive = try Archive(data: data, accessMode: .read)
    var files: [String: Data] = [:]
    var seen: Set<String> = []
    var total = 0
    for entry in archive {
      try Task.checkCancellation()
      let path = entry.type == .directory && entry.path.hasSuffix("/") ? String(entry.path.dropLast()) : entry.path
      guard seen.count < 1024, Self.validPath(path), seen.insert(path).inserted,
            entry.type != .symlink, entry.uncompressedSize <= UInt64(maximumBytes - total) else {
        throw ADBError.parseFailure("invalid tool archive entry")
      }
      if entry.type == .directory { continue }
      var content = Data()
      let checksum = try archive.extract(entry, bufferSize: 16384) { chunk in
        try Task.checkCancellation()
        guard content.count + chunk.count <= maximumBytes - total else {
          throw ADBError.parseFailure("expanded tool assets are too large")
        }
        content.append(chunk)
      }
      guard checksum == entry.checksum, content.count == entry.uncompressedSize else {
        throw ADBError.parseFailure("tool archive checksum or size mismatch")
      }
      total += content.count
      files[path] = content
    }
    try self.init(files: files)
  }

  public init(files: [String: Data]) throws {
    guard !files.isEmpty, files.count <= 1024, files.keys.allSatisfy(Self.validPath),
          files.values.reduce(0, { $0 + $1.count }) <= 16 * 1024 * 1024,
          let html = files["index.html"], html.count <= 4 * 1024 * 1024,
          String(data: html, encoding: .utf8) != nil else {
      throw ADBError.parseFailure("invalid tool frontend assets")
    }
    self.files = files
  }

  static func validPath(_ path: String) -> Bool {
    !path.isEmpty && path.utf16.count <= 1024 && !path.contains("\\")
      && !path.unicodeScalars.contains { $0.value < 32 || $0.value == 127 }
      && !path.split(separator: "/", omittingEmptySubsequences: false).contains { $0.isEmpty || $0 == "." || $0 == ".." }
  }

  static func request(manifest: PluginProcessMetadata, tool: PluginDescriptor) throws -> Data {
    guard let identity = PluginProcessIdentity(metadata: manifest) else {
      throw ADBError.parseFailure("tool process identity is missing or invalid")
    }
    return try request(identity: identity, tool: tool)
  }

  static func request(identity: PluginProcessIdentity, tool: PluginDescriptor) throws -> Data {
    struct Request: Encodable {
      let processIdentity: String
      let androidUserId: Int
      let packageName: String
      let revision: String
      let pluginId: PluginID
      let assetPath: String
      let hostApiVersion: Int

      private enum CodingKeys: String, CodingKey {
        case processIdentity, androidUserId, packageName, revision, assetPath, hostApiVersion
        case pluginId = "inspectorId"
      }
    }
    guard let frontend = tool.frontend, validPath(frontend.assetPath), frontend.assetPath.hasSuffix(".zip") else {
      throw ADBError.parseFailure("tool frontend metadata is missing or invalid")
    }
    return try JSONEncoder().encode(Request(
      processIdentity: identity.processIdentity, androidUserId: identity.androidUserId,
      packageName: identity.packageName, revision: identity.revision,
      pluginId: tool.id, assetPath: frontend.assetPath, hostApiVersion: frontend.hostApiVersion
    ))
  }
}
