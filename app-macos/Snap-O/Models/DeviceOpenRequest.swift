import Foundation

enum DeviceOpenRequest: Equatable {
  case serial(String)
  case device(DeviceID)
  case avd(String, start: Bool)

  var name: String {
    switch self {
    case .serial(let serial): DeviceID(storedValue: serial).serial
    case .device(let id): id.serial
    case .avd(let name, _): name
    }
  }

  init?(url: URL) {
    guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
          components.scheme?.lowercased() == "snapo",
          components.host?.lowercased() == "open",
          components.path.isEmpty || components.path == "/",
          components.user == nil, components.password == nil,
          components.port == nil, components.fragment == nil else { return nil }
    let items = components.queryItems ?? []
    guard items.allSatisfy({ ["serial", "avd", "start", "server"].contains($0.name) }),
          Set(items.map(\.name)).count == items.count else { return nil }
    let serial = items.first { $0.name == "serial" }
    let avd = items.first { $0.name == "avd" }
    let server = items.first { $0.name == "server" }
    let start = items.first { $0.name == "start" }
    guard (serial == nil) != (avd == nil),
          let name = (serial ?? avd)?.value, !name.isEmpty, name.utf8.count <= 512,
          !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
    if serial != nil {
      guard start == nil else { return nil }
      if let server {
        guard let value = server.value, value == "local" || UUID(uuidString: value) != nil else { return nil }
        self = .device(DeviceID(serverID: UUID(uuidString: value).map(ADBServerID.remote) ?? .local, serial: name))
      } else {
        self = .serial(name)
      }
    } else {
      guard server == nil, start == nil || start?.value == "true" || start?.value == "false" else { return nil }
      self = .avd(name, start: start?.value == "true")
    }
  }

  var url: URL? {
    var components = URLComponents()
    components.scheme = "snapo"
    components.host = "open"
    switch self {
    case .serial(let serial):
      components.queryItems = [URLQueryItem(name: "serial", value: serial)]
    case .device(let id):
      let server: String = switch id.serverID {
      case .local: "local"
      case .remote(let id): id.uuidString.lowercased()
      }
      components.queryItems = [URLQueryItem(name: "serial", value: id.serial), URLQueryItem(name: "server", value: server)]
    case .avd(let name, let start):
      components.queryItems = [URLQueryItem(name: "avd", value: name)]
      if start { components.queryItems?.append(URLQueryItem(name: "start", value: "true")) }
    }
    return components.url
  }
}
