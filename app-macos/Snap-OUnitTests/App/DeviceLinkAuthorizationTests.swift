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
    #expect(authorization.requiresApproval(.serial("phone", server: .ssh(destination: "test-host"))))
    let result = try await authorization.authorize(.serial("phone", server: .ssh(destination: "test-host")))
    #expect(result == (approved ? .serial("phone", server: server, serverID: id) : nil))
    #expect(enables == (approved ? 1 : 0))
  }

  @Test
  func enabledServerSkipsApproval() async throws {
    let authorization = DeviceLinkAuthorization(
      servers: { [id: DeviceLinkConnection(server: server)] },
      confirmEnable: { _, _ in Issue.record("Unexpected confirmation")
        return false
      },
      enable: { _, _ in Issue.record("Unexpected enable") }
    )
    #expect(!authorization.requiresApproval(.serial("phone", server: server)))
    let result = try await authorization.authorize(.serial("phone", server: server))
    #expect(result == .serial("phone", server: server, serverID: id))
  }

  @Test
  func changedConfigurationCannotInheritApproval() async {
    var connection = server
    let authorization = DeviceLinkAuthorization(
      servers: { [id: DeviceLinkConnection(server: connection, isEnabled: false)] },
      confirmEnable: { _, _ in connection = .ssh(destination: "different-host")
        return true
      },
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
      confirmEnable: { _, _ in Issue.record("Ambiguous destination must not be offered")
        return false
      },
      enable: { _, _ in Issue.record("Unexpected enable") }
    )
    #expect(!authorization.requiresApproval(request))
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

  @Test(arguments: [false, true])
  func unknownServerRequiresReviewBeforeOpeningEditor(review: Bool) async throws {
    var edits = 0
    let authorization = DeviceLinkAuthorization(
      servers: { [:] },
      confirmEnable: { _, _ in Issue.record("Unknown server cannot be enabled")
        return false
      },
      confirmAdd: {
        #expect(edits == 0)
        return review
      },
      addServer: { requestedServer in
        #expect(requestedServer == server)
        edits += 1
        return nil
      },
      enable: { _, _ in Issue.record("Unknown server cannot be enabled") }
    )
    #expect(authorization.requiresApproval(.serial("phone", server: server)))
    #expect(try await authorization.authorize(.serial("phone", server: server)) == nil)
    #expect(edits == (review ? 1 : 0))
  }

  @Test
  func opensOriginalDeviceOnEditedServerAfterSaving() async throws {
    let editedServer = DeviceLinkServer.ssh(destination: "reviewed-host", port: 2223, adbPort: 5038)
    var saved = false
    let authorization = DeviceLinkAuthorization(
      servers: { [:] },
      confirmEnable: { _, _ in Issue.record("Unexpected enable prompt")
        return false
      },
      confirmAdd: { true },
      addServer: { _ in
        saved = true
        return (id, editedServer)
      },
      enable: { _, _ in Issue.record("Unexpected enable") }
    )
    let result = try await authorization.authorize(.serial("phone", server: server))
    #expect(saved)
    #expect(result == .serial("phone", server: editedServer, serverID: id))
  }

  @Test
  func failedSaveDoesNotOpenDevice() async {
    let authorization = DeviceLinkAuthorization(
      servers: { [:] },
      confirmEnable: { _, _ in Issue.record("Unexpected enable prompt")
        return false
      },
      confirmAdd: { true },
      addServer: { _ in throw DeviceOpenError(message: "Synthetic save failure") },
      enable: { _, _ in Issue.record("Unexpected enable") }
    )
    await #expect(throws: DeviceOpenError.self) {
      try await authorization.authorize(.serial("phone", server: server))
    }
  }
}
