import Foundation

enum DeviceOpenRequest: Equatable {
  case serial(String)
  case avd(String, start: Bool)

  var name: String {
    switch self {
    case .serial(let serial): serial
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
    guard items.allSatisfy({ ["serial", "avd", "start"].contains($0.name) }),
          Set(items.map(\.name)).count == items.count else { return nil }
    let serial = items.first { $0.name == "serial" }
    let avd = items.first { $0.name == "avd" }
    let start = items.first { $0.name == "start" }
    guard (serial == nil) != (avd == nil),
          let name = (serial ?? avd)?.value, !name.isEmpty, name.utf8.count <= 512,
          !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
    if serial != nil {
      guard start == nil else { return nil }
      self = .serial(name)
    } else {
      guard start == nil || start?.value == "true" || start?.value == "false" else { return nil }
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
    case .avd(let name, let start):
      components.queryItems = [URLQueryItem(name: "avd", value: name)]
      if start { components.queryItems?.append(URLQueryItem(name: "start", value: "true")) }
    }
    return components.url
  }
}
