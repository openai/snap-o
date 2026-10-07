import Foundation

struct ADBServerStore {
  private static let key = "remoteADBServers"
  let defaults: UserDefaults

  func load() throws -> [RemoteADBServer] {
    guard let data = defaults.data(forKey: Self.key) else {
      return []
    }
    let servers = try JSONDecoder().decode([RemoteADBServer].self, from: data)
    try Self.validate(servers)
    return servers
  }

  func save(_ servers: [RemoteADBServer]) throws {
    try Self.validate(servers)
    try defaults.set(JSONEncoder().encode(servers), forKey: Self.key)
  }

  private static func validate(_ servers: [RemoteADBServer]) throws {
    guard Set(servers.map(\.id)).count == servers.count else {
      throw ADBError.protocolFailure("Saved ADB servers contain duplicate identifiers.")
    }
    for server in servers {
      try server.connection.validate()
    }
  }
}
