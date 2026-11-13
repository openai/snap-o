import Foundation
import Testing

@Suite("Wireless ADB")
struct WirelessADBTests {
  @Test(arguments: ["", "phone", "phone:0", "phone:65536", "phone:5555\nhost:kill", "phone:1:2", "$(id):5555"])
  func rejectsInvalidEndpoints(address: String) {
    #expect(throws: WirelessADBError.self) { try WirelessADBEndpoint(address) }
  }

  @Test(arguments: ["192.168.1.10:37123", "phone.local:37123", "[2001:db8::1]:37123"])
  func acceptsExplicitEndpoints(address: String) throws {
    #expect(try WirelessADBEndpoint(address).address == address)
  }

  @Test
  func pairsWithoutSelectingADeviceTransport() async throws {
    let connection = ScriptedADBConnection(commandReply: "Successfully paired to 192.168.1.10:37123 [guid=test]")
    let client = ADBClient(discoveryTimeout: .seconds(1)) { connection }
    try await client.pairWirelessDevice(at: WirelessADBEndpoint("192.168.1.10:37123"), code: "123456")
    #expect(connection.commands == ["host:pair:123456:192.168.1.10:37123"])
    #expect(connection.isClosed)
  }

  @Test(arguments: ["12345", "1234567", "１２３４５６", "123:45", "123\n45"])
  func rejectsInvalidCodesBeforeConnecting(code: String) async throws {
    let client = ADBClient(discoveryTimeout: .seconds(1)) {
      Issue.record("Invalid codes must not open a connection")
      return ScriptedADBConnection()
    }
    await #expect(throws: WirelessADBError.self) {
      try await client.pairWirelessDevice(at: WirelessADBEndpoint("phone:37123"), code: code)
    }
  }

  @Test(arguments: ["connected to phone:37123", "already connected to phone:37123"])
  func acceptsConnectedResponses(response: String) async throws {
    let connection = ScriptedADBConnection(commandReply: response)
    let client = ADBClient(discoveryTimeout: .seconds(1)) { connection }
    try await client.connectWirelessDevice(at: WirelessADBEndpoint("phone:37123"))
    #expect(connection.commands == ["host:connect:phone:37123"])
    #expect(connection.isClosed)
  }

  @Test(arguments: ["failed to connect to phone:37123", "connected to another-phone:37123", ""])
  func okayStatusDoesNotMeanConnectionSucceeded(response: String) async throws {
    let connection = ScriptedADBConnection(commandReply: response)
    let client = ADBClient(discoveryTimeout: .seconds(1)) { connection }
    await #expect(throws: WirelessADBError.self) {
      try await client.connectWirelessDevice(at: WirelessADBEndpoint("phone:37123"))
    }
    #expect(connection.isClosed)
  }

  @Test
  func pairingFailureDoesNotExposeTheServerResponse() async throws {
    let connection = ScriptedADBConnection(commandReply: "Rejected secret code 123456")
    let client = ADBClient(discoveryTimeout: .seconds(1)) { connection }
    do {
      try await client.pairWirelessDevice(at: WirelessADBEndpoint("phone:37123"), code: "123456")
      Issue.record("A rejected pairing must fail")
    } catch {
      #expect(!error.localizedDescription.contains("123456"))
    }
    #expect(connection.commands.count == 1)
    #expect(connection.isClosed)
  }

  @Test
  func cancellationClosesPairingWithoutRetry() async throws {
    let connection = ScriptedADBConnection(blockedCommand: "host:pair:123456:phone:37123")
    let client = ADBClient(discoveryTimeout: .seconds(1)) { connection }
    let operation = Task {
      try await client.pairWirelessDevice(at: WirelessADBEndpoint("phone:37123"), code: "123456")
    }
    try await connection.waitUntilBlocked()
    operation.cancel()
    await #expect(throws: CancellationError.self) { try await operation.value }
    #expect(connection.commands.count == 1)
    #expect(connection.isClosed)
  }
}
