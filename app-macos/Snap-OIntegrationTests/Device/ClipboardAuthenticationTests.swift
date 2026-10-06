import Foundation
@testable import Snap_O
import Testing

struct ClipboardAuthenticationTests {
  @MainActor
  @Test
  func refreshesJWTBeforeExpiryAndReusesStaticTokens() async throws {
    let now = Date(timeIntervalSince1970: 1000)
    var refreshes = 0
    let authentication = EmulatorClipboardAuthentication(
      endpoint: EmulatorGRPCEndpoint(port: 8554, token: "initial", expiresAt: now.addingTimeInterval(900))
    ) {
      refreshes += 1
      return EmulatorGRPCEndpoint(port: 8554, token: "renewed", expiresAt: now.addingTimeInterval(1800))
    }
    #expect(try await authentication.token(at: now) == "initial")
    #expect(refreshes == 0)
    #expect(try await authentication.token(at: now.addingTimeInterval(840)) == "renewed")
    #expect(try await authentication.token(at: now.addingTimeInterval(950)) == "renewed")
    #expect(refreshes == 1)
    let staticAuthentication = EmulatorClipboardAuthentication(endpoint: EmulatorGRPCEndpoint(port: 8554, token: "static")) {
      Issue.record("Static tokens do not need renewal")
      throw CancellationError()
    }
    #expect(try await staticAuthentication.token(at: now.addingTimeInterval(3600)) == "static")
  }

  @MainActor
  @Test
  func rejectsChangedEndpointsAndMissingAuthentication() async {
    let authentication = EmulatorClipboardAuthentication(
      endpoint: EmulatorGRPCEndpoint(port: 8554, token: "initial", expiresAt: .distantPast)
    ) { EmulatorGRPCEndpoint(port: 8555, token: "other-emulator") }
    await #expect(throws: AndroidHostClientError.self) { try await authentication.token() }
    let unauthenticated = EmulatorClipboardAuthentication(endpoint: EmulatorGRPCEndpoint(port: 8554, token: nil)) {
      throw CancellationError()
    }
    await #expect(throws: AndroidHostClientError.self) { try await unauthenticated.token() }
  }
}
