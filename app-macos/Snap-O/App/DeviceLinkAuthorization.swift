import Foundation

@MainActor
struct DeviceLinkAuthorization {
  var servers: () -> [ADBServerID: DeviceLinkConnection]
  var confirmEnable: (DeviceLinkServer, String) async -> Bool
  var enable: (ADBServerID, DeviceLinkServer) async throws -> Void

  func authorize(_ request: DeviceOpenRequest) async throws -> DeviceOpenRequest? {
    guard case .serial(let serial, let server, _) = request,
          case .ssh = server else { return request }
    let matches = servers().filter { server.matches($0.value.server) }
    let enabled = matches.filter(\.value.isEnabled)
    if enabled.count == 1, let match = enabled.first {
      return .serial(serial, server: match.value.server, serverID: match.key)
    }
    // The resolver reports missing or ambiguous configurations without changing them.
    guard enabled.isEmpty, matches.count == 1, let match = matches.first else { return request }
    guard await confirmEnable(match.value.server, serial) else { return nil }
    guard servers()[match.key]?.server == match.value.server else {
      throw DeviceOpenError(message: "The server configuration changed. Open the link again to review it.")
    }
    try await enable(match.key, match.value.server)
    return .serial(serial, server: match.value.server, serverID: match.key)
  }
}
