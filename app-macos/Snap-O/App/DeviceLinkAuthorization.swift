import Foundation

@MainActor
struct DeviceLinkAuthorization {
  var servers: () -> [ADBServerID: DeviceLinkConnection]
  var confirmEnable: (DeviceLinkServer, String) async -> Bool
  var confirmAdd: () async -> Bool = { false }
  var addServer: (DeviceLinkServer) async throws -> (id: ADBServerID, server: DeviceLinkServer)? = { _ in nil }
  var enable: (ADBServerID, DeviceLinkServer) async throws -> Void

  func requiresApproval(_ request: DeviceOpenRequest) -> Bool {
    guard case .serial(_, let server, _) = request, case .ssh = server else { return false }
    let matches = servers().values.filter { server.matches($0.server) }
    return matches.count <= 1 && !matches.contains(where: \.isEnabled)
  }

  func authorize(_ request: DeviceOpenRequest) async throws -> DeviceOpenRequest? {
    guard case .serial(let serial, let server, _) = request,
          case .ssh = server else { return request }
    let matches = servers().filter { server.matches($0.value.server) }
    if matches.isEmpty {
      guard await confirmAdd(),
            let added = try await addServer(server) else { return nil }
      return .serial(serial, server: added.server, serverID: added.id)
    }
    let enabled = matches.filter(\.value.isEnabled)
    if enabled.count == 1, let match = enabled.first {
      return .serial(serial, server: match.value.server, serverID: match.key)
    }
    // The resolver reports ambiguous configurations without changing them.
    guard enabled.isEmpty, matches.count == 1, let match = matches.first else { return request }
    guard await confirmEnable(match.value.server, serial) else { return nil }
    guard servers()[match.key]?.server == match.value.server else {
      throw DeviceOpenError(message: "The server configuration changed. Open the link again to review it.")
    }
    try await enable(match.key, match.value.server)
    return .serial(serial, server: match.value.server, serverID: match.key)
  }
}
