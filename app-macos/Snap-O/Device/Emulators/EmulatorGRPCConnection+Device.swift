import GRPCCore
import GRPCNIOTransportHTTP2TransportServices
import Synchronization

extension EmulatorGRPCConnection {
  static func withConsole<Result: Sendable>(
    target: DeviceTarget,
    endpoint: EmulatorGRPCEndpoint,
    isolation: isolated (any Actor)? = #isolation,
    body: (EmulatorNativeConnection) async throws -> Result
  ) async throws -> Result {
    guard let processID = endpoint.processID, processID > 0 else {
      throw RPCError(code: .failedPrecondition, message: "The emulator process could not be identified.")
    }
    let clientPort = Mutex<Int?>(nil)
    let connected: @Sendable (Int) -> Void = { port in clientPort.withLock { $0 = port } }
    return try await withDevice(target: target, endpoint: endpoint, connected: connected, isolation: isolation) { _, _ in
      guard let port = clientPort.withLock({ $0 }) else {
        throw RPCError(code: .failedPrecondition, message: "The emulator connection could not be identified.")
      }
      return try await body(EmulatorNativeConnection(processID: processID, grpcPort: endpoint.port, clientPort: port))
    }
  }

  static func withDevice<Result: Sendable>(
    target: DeviceTarget,
    endpoint: EmulatorGRPCEndpoint,
    connected: @escaping @Sendable (Int) -> Void = { _ in },
    isolation: isolated (any Actor)? = #isolation,
    body: (GRPCClient<HTTP2ClientTransport.WrappedChannel>, Metadata) async throws -> Result
  ) async throws -> Result {
    _ = try target.requireTransport(for: target.serial)
    let transport = try await open(port: endpoint.port, connected: connected)
    var metadata = Metadata()
    if let token = endpoint.token { metadata.addString("Bearer " + token, forKey: "authorization") }
    let authorization = metadata
    return try await withGRPCClient(transport: transport, isolation: isolation) { client in
      try await verify(client: client, metadata: authorization) { marker in
        _ = try await ADBClient().bound(to: target).withTimeout(.seconds(2)).runShellString(
          deviceID: target.serial, command: "log -p i -t SnapOConnection " + marker
        )
      }
      try Task.checkCancellation()
      _ = try target.requireTransport(for: target.serial)
      return try await body(client, authorization)
    }
  }
}
