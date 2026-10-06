import Foundation

@MainActor
extension EmulatorControlsController {
  static func live(target: DeviceTarget) -> EmulatorControlsController {
    let client = AndroidHostClient()
    return EmulatorControlsController(
      target: target,
      load: { target in
        try await withNativeConnection(target: target, client: client) { native in
          try await client.controls(target: target, native: native)
        }
      },
      apply: { target, path, action in
        try await withNativeConnection(target: target, client: client) { native in
          try await client.control(target: target, native: native, avdPath: path, action: action)
        }
      },
      close: { client.close() }
    )
  }

  private static func withNativeConnection<Value: Sendable>(
    target: DeviceTarget,
    client: AndroidHostClient,
    body: (EmulatorNativeConnection) async throws -> Value
  ) async throws -> Value {
    guard let endpoint = try await client.previewEndpoint(target.serial) else {
      throw AndroidHostClientError(message: "The emulator connection is not ready.")
    }
    return try await EmulatorGRPCConnection.withConsole(target: target, endpoint: endpoint, body: body)
  }
}
