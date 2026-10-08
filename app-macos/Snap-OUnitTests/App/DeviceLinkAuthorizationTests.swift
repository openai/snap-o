import Foundation
import Testing

@MainActor
struct DeviceLinkAuthorizationTests {
  private let server = DeviceLinkServer.ssh(destination: "test-host", port: 2222)
  private let id = ADBServerID.remote(UUID())

  @Test(arguments: [false, true])
  func disabledServerRequiresApproval(approved: Bool) async throws {
    var enables = 0
    let authorization = DeviceLinkAuthorization(
      servers: { [id: DeviceLinkConnection(server: server, isEnabled: false)] },
      confirmEnable: { connection, serial in
        #expect(connection == server && serial == "phone")
        #expect(enables == 0)
        return approved
      },
      enable: { selected, connection in
        #expect(selected == id && connection == server)
        enables += 1
      }
    )
    let result = try await authorization.authorize(.serial("phone", server: .ssh(destination: "test-host")))
    #expect(result == (approved ? .serial("phone", server: server, serverID: id) : nil))
    #expect(enables == (approved ? 1 : 0))
  }

  @Test
  func enabledServerSkipsApproval() async throws {
    let authorization = DeviceLinkAuthorization(
      servers: { [id: DeviceLinkConnection(server: server)] },
      confirmEnable: { _, _ in Issue.record("Unexpected confirmation"); return false },
      enable: { _, _ in Issue.record("Unexpected enable") }
    )
    #expect(try await authorization.authorize(.serial("phone", server: server)) == .serial("phone", server: server, serverID: id))
  }

  @Test
  func changedConfigurationCannotInheritApproval() async {
    var connection = server
    let authorization = DeviceLinkAuthorization(
      servers: { [id: DeviceLinkConnection(server: connection, isEnabled: false)] },
      confirmEnable: { _, _ in connection = .ssh(destination: "different-host"); return true },
      enable: { _, _ in Issue.record("Changed destination must not be enabled") }
    )
    await #expect(throws: DeviceOpenError.self) {
      try await authorization.authorize(.serial("phone", server: server))
    }
  }

  @Test
  func ambiguousDisabledServersAreNotEnabled() async throws {
    let request = DeviceOpenRequest.serial("phone", server: .ssh(destination: "test-host"))
    let authorization = DeviceLinkAuthorization(
      servers: { [
        id: DeviceLinkConnection(server: server, isEnabled: false),
        .remote(UUID()): DeviceLinkConnection(server: .ssh(destination: "test-host", port: 2223), isEnabled: false)
    ] },
      confirmEnable: { _, _ in Issue.record("Ambiguous destination must not be offered"); return false },
      enable: { _, _ in Issue.record("Unexpected enable") }
    )
    #expect(try await authorization.authorize(request) == request)
  }

  @Test
  func enableFailureDoesNotOpenDevice() async {
    let authorization = DeviceLinkAuthorization(
      servers: { [id: DeviceLinkConnection(server: server, isEnabled: false)] },
      confirmEnable: { _, _ in true },
      enable: { _, _ in throw DeviceOpenError(message: "Synthetic save failure") }
    )
    await #expect(throws: DeviceOpenError.self) {
      try await authorization.authorize(.serial("phone", server: server))
    }
  }
}
