import Foundation
import SnapODeviceClient

struct InspectorPlugin: Decodable, Identifiable {
  struct Discovery: Decodable {
    let socketPrefix: String
  }

  let manifestVersion: Int
  let id: InspectorID
  let name: String
  let icon: String
  let hostApiVersion: Int
  let discovery: Discovery
  var resourceDirectory: URL?
  var iconBase64: String?

  private enum CodingKeys: String, CodingKey {
    case manifestVersion, id, name, icon, hostApiVersion, discovery
  }

  var socketDefinition: InspectorSocketDefinition {
    InspectorSocketDefinition(id: id, socketPrefix: discovery.socketPrefix)
  }
}

struct InspectorPluginRegistry {
  let plugins: [InspectorPlugin]

  init(directory: URL) throws {
    let root = directory.resolvingSymlinksInPath().standardizedFileURL.path + "/"
    let directories = try FileManager.default.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: nil
    ).sorted { $0.lastPathComponent < $1.lastPathComponent }
    var plugins: [InspectorPlugin] = []
    for directory in directories {
      let manifest = directory.appendingPathComponent("plugin.json")
      guard FileManager.default.fileExists(atPath: manifest.path) else { continue }
      var plugin = try JSONDecoder().decode(InspectorPlugin.self, from: Data(contentsOf: manifest))
      guard directory.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(root),
            plugin.manifestVersion == 1, plugin.hostApiVersion == 1,
            plugin.id.rawValue.range(of: "^[a-z][a-z0-9.-]{0,99}$", options: .regularExpression) != nil,
            directory.lastPathComponent == plugin.id.rawValue,
            !plugin.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            !plugin.icon.isEmpty,
            plugin.discovery.socketPrefix.range(of: "^[A-Za-z][A-Za-z0-9_]*_$", options: .regularExpression) != nil,
            Self.validEntry(in: directory),
            !plugins.contains(where: {
              $0.id == plugin.id || $0.discovery.socketPrefix.hasPrefix(plugin.discovery.socketPrefix)
                || plugin.discovery.socketPrefix.hasPrefix($0.discovery.socketPrefix)
            }) else { throw RegistryError.invalidManifest(directory.lastPathComponent) }
      plugin.resourceDirectory = directory
      if plugin.icon.hasSuffix(".png") {
        let icon = directory.appendingPathComponent(plugin.icon).resolvingSymlinksInPath().standardizedFileURL
        guard icon.path.hasPrefix(directory.resolvingSymlinksInPath().standardizedFileURL.path + "/"),
              let data = try? Data(contentsOf: icon), data.count <= 1_048_576,
              data.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) else {
          throw RegistryError.invalidManifest(directory.lastPathComponent)
        }
        plugin.iconBase64 = data.base64EncodedString()
      }
      plugins.append(plugin)
    }
    self.plugins = plugins
  }

  static func bundled() throws -> Self {
    guard let resources = Bundle.main.resourceURL else { throw RegistryError.missingResources }
    return try Self(directory: resources.appendingPathComponent("Inspectors"))
  }

  func plugin(for id: InspectorID) -> InspectorPlugin? {
    plugins.first { $0.id == id }
  }

  var socketDefinitions: [InspectorSocketDefinition] {
    plugins.map(\.socketDefinition)
  }

  private static func validEntry(in directory: URL) -> Bool {
    let root = directory.resolvingSymlinksInPath().standardizedFileURL.path + "/"
    let file = directory.appendingPathComponent("index.html").resolvingSymlinksInPath().standardizedFileURL
    return file.path.hasPrefix(root)
      && (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
  }

  private enum RegistryError: LocalizedError {
    case missingResources
    case invalidManifest(String)
    var errorDescription: String? {
      switch self {
      case .missingResources: "Inspector resources are unavailable."
      case .invalidManifest(let id): "Invalid inspector plugin: \(id)."
      }
    }
  }
}
