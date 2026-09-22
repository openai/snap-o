import Foundation

@MainActor
final class EmulatorClipboardAuthentication {
  private var endpoint: EmulatorGRPCEndpoint
  private let refresh: () async throws -> EmulatorGRPCEndpoint

  init(endpoint: EmulatorGRPCEndpoint, refresh: @escaping () async throws -> EmulatorGRPCEndpoint) {
    self.endpoint = endpoint
    self.refresh = refresh
  }

  func token(at now: Date = .now) async throws -> String {
    if let expiresAt = endpoint.expiresAt, expiresAt.timeIntervalSince(now) <= 60 {
      let renewed = try await refresh()
      // A restarted emulator needs a new transport, not credentials sent to the old port.
      guard renewed.port == endpoint.port else {
        throw EmulatorClientError(message: "The emulator's clipboard endpoint changed. Reconnecting.")
      }
      endpoint = renewed
    }
    guard let token = endpoint.token, !token.isEmpty else {
      throw EmulatorClientError(message: "Clipboard sync requires an authenticated emulator.")
    }
    return token
  }
}
