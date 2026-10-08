import Foundation

enum DeviceLinkServer: Equatable {
  case local(adbPort: UInt16 = 5037)
  case ssh(destination: String, port: UInt16? = nil, adbPort: UInt16 = 5037)

  func matches(_ connection: DeviceLinkServer) -> Bool {
    switch (self, connection) {
    case (.local(let adbPort), .local(let connectedPort)):
      adbPort == connectedPort
    case (.ssh(let destination, let port, let adbPort), .ssh(let connectedDestination, let connectedPort, let connectedADBPort)):
      destination == connectedDestination && adbPort == connectedADBPort && (port == nil || port == connectedPort)
    default:
      false
    }
  }
}

enum DeviceOpenURL: Equatable {
  case currentPreview
  case target(DeviceOpenRequest)

  init?(url: URL) {
    guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
          components.scheme?.lowercased() == "snapo",
          components.host?.lowercased() == "open",
          components.path.isEmpty || components.path == "/",
          components.user == nil, components.password == nil,
          components.port == nil, components.fragment == nil else { return nil }
    let items = components.queryItems ?? []
    if items.isEmpty {
      self = .currentPreview
    } else {
      guard let request = DeviceOpenRequest(queryItems: items) else { return nil }
      self = .target(request)
    }
  }
}

enum DeviceOpenRequest: Equatable {
  case serial(String, server: DeviceLinkServer = .local())
  case device(DeviceID)
  case avd(String, start: Bool)

  fileprivate init?(queryItems items: [URLQueryItem]) {
    guard items.allSatisfy({ ["serial", "avd", "start", "server", "port", "adb_port"].contains($0.name) }),
          Set(items.map(\.name)).count == items.count else { return nil }
    let values = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
    guard (values["serial"] == nil) != (values["avd"] == nil),
          let name = values["serial"] ?? values["avd"], !name.isEmpty, name.utf8.count <= 512,
          !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
    if values["serial"] != nil {
      guard values["start"] == nil else { return nil }
      let port = Self.port(values["port"])
      let adbPort = Self.port(values["adb_port"])
      guard values["port"] == nil || port != nil,
            values["adb_port"] == nil || adbPort != nil else { return nil }
      let destination = values["server"] ?? "localhost"
      if destination.lowercased() == "localhost" {
        guard port == nil else { return nil }
        self = .serial(name, server: .local(adbPort: adbPort ?? 5037))
      } else {
        guard !destination.isEmpty, destination.utf8.count <= 512, !destination.hasPrefix("-"),
              !destination.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains($0) })
        else { return nil }
        self = .serial(name, server: .ssh(destination: destination, port: port, adbPort: adbPort ?? 5037))
      }
    } else {
      guard values["server"] == nil, values["port"] == nil, values["adb_port"] == nil,
            values["start"] == nil || values["start"] == "true" || values["start"] == "false" else { return nil }
      self = .avd(name, start: values["start"] == "true")
    }
  }

  private static func port(_ value: String?) -> UInt16? {
    guard let value, !value.isEmpty, value.utf8.allSatisfy({ (48 ... 57).contains($0) }),
          let port = UInt16(value), port > 0 else { return nil }
    return port
  }
}
