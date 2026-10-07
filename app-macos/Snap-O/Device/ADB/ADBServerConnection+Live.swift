import Foundation

extension ADBServerConnection {
  static func tracker(for profile: RemoteADBServer) -> any DeviceTracking {
    switch profile.connection {
    case .ssh(let configuration):
      sshTracker(serverID: profile.id, configuration: configuration)
    }
  }

  private static func sshTracker(serverID: UUID, configuration: SSHConfiguration) -> any DeviceTracking {
    let host = AndroidHostClient()
    let connection = ADBServerConnection(
      serverID: serverID, configuration: configuration,
      openTunnel: { try await host.openADBTunnel(id: $0, configuration: $1) },
      socketFactory: { host.tunnelSocketFactory(id: $0) },
      closeTunnel: { await host.closeADBTunnel(id: $0) },
      disconnect: { host.close() }
    )
    return DeviceTracker(
      connect: { try await connection.client() },
      disconnect: { await connection.close() },
      retriesWithBackoff: true
    )
  }
}
