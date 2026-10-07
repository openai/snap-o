import Foundation

struct RemoteADBServer {
  let id: UUID
  let ssh: SSHConfiguration
}

/// Owns the tunnel used by one tracker. The tracker alone schedules retries.
@MainActor
final class ADBServerConnection {
  private let configuration: RemoteADBServer
  private let openTunnel: (String, SSHConfiguration) async throws -> ADBTunnelHandle
  private let socketFactory: (String) -> (@Sendable () throws -> FileHandle)
  private let closeTunnel: (String) async -> Void
  private let disconnect: () -> Void
  private var tunnelID: String?
  private var startup: Task<ADBTunnelHandle, Error>?
  private var closing: Task<Void, Never>?

  init(
    configuration: RemoteADBServer,
    openTunnel: @escaping (String, SSHConfiguration) async throws -> ADBTunnelHandle,
    socketFactory: @escaping (String) -> (@Sendable () throws -> FileHandle),
    closeTunnel: @escaping (String) async -> Void,
    disconnect: @escaping () -> Void
  ) {
    self.configuration = configuration
    self.openTunnel = openTunnel
    self.socketFactory = socketFactory
    self.closeTunnel = closeTunnel
    self.disconnect = disconnect
  }

  func client() async throws -> ADBClient {
    await closing?.value
    try Task.checkCancellation()
    precondition(tunnelID == nil)
    let id = UUID().uuidString
    tunnelID = id
    let task = Task { try await openTunnel(id, configuration.ssh) }
    startup = task
    do {
      let tunnel = try await withTaskCancellationHandler { try await task.value } onCancel: {
        task.cancel()
        Task { @MainActor [weak self] in
          guard let self, tunnelID == id else { return }
          await close()
        }
      }
      guard tunnelID == id else { throw CancellationError() }
      try Task.checkCancellation()
      guard tunnel.id == id else { throw ADBError.protocolFailure("Unexpected ADB tunnel reply") }
      let openSocket = socketFactory(id)
      return ADBClient(serverID: .remote(configuration.id)) {
        try ADBSocketConnection(fileHandle: openSocket())
      }
    } catch {
      await closeTunnel(id)
      if tunnelID == id { tunnelID = nil }
      throw error
    }
  }

  func close() async {
    if let closing { await closing.value
      return
    }
    let id = tunnelID
    tunnelID = nil
    let pending = startup
    pending?.cancel()
    let task = Task {
      if let id { await closeTunnel(id) }
      _ = await pending?.result
      disconnect()
    }
    closing = task
    await task.value
    startup = nil
    closing = nil
  }
}
