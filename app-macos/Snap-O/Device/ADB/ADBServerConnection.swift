import Foundation

struct RemoteADBServer: Codable, Equatable, Identifiable {
  let id: UUID
  var connection: Connection

  enum Connection: Codable, Equatable {
    case ssh(SSHConfiguration)

    private enum Kind: String, Codable { case ssh }
    private enum CodingKeys: String, CodingKey { case type, ssh }

    init(from decoder: any Decoder) throws {
      let values = try decoder.container(keyedBy: CodingKeys.self)
      switch try values.decode(Kind.self, forKey: .type) {
      case .ssh: self = try .ssh(values.decode(SSHConfiguration.self, forKey: .ssh))
      }
    }

    func encode(to encoder: any Encoder) throws {
      var values = encoder.container(keyedBy: CodingKeys.self)
      switch self {
      case .ssh(let configuration):
        try values.encode(Kind.ssh, forKey: .type)
        try values.encode(configuration, forKey: .ssh)
      }
    }

    var displayAddress: String {
      switch self {
      case .ssh(let configuration): configuration.displayAddress
      }
    }

    func validate() throws {
      switch self {
      case .ssh(let configuration): try configuration.validate()
      }
    }
  }
}

/// Owns the tunnel used by one tracker. The tracker alone schedules retries.
@MainActor
final class ADBServerConnection {
  private let serverID: UUID
  private let configuration: SSHConfiguration
  private let openTunnel: (String, SSHConfiguration) async throws -> ADBTunnelHandle
  private let socketFactory: (String) -> (@Sendable () throws -> FileHandle)
  private let closeTunnel: (String) async -> Void
  private let disconnect: () -> Void
  private var tunnelID: String?
  private var startup: Task<ADBTunnelHandle, Error>?
  private var closing: Task<Void, Never>?

  init(
    serverID: UUID, configuration: SSHConfiguration,
    openTunnel: @escaping (String, SSHConfiguration) async throws -> ADBTunnelHandle,
    socketFactory: @escaping (String) -> (@Sendable () throws -> FileHandle),
    closeTunnel: @escaping (String) async -> Void,
    disconnect: @escaping () -> Void
  ) {
    self.serverID = serverID
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
    let task = Task { try await openTunnel(id, configuration) }
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
      return ADBClient(serverID: .remote(serverID)) {
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
