import Clocks
import DependenciesTestSupport
import Foundation
import Testing

@Suite("ADB local socket admission", .dependency(\.continuousClock, TestClock()))
struct ADBLocalSocketQueueTests {
  private let name = "snapo_network_42"
  private var listener: String { "1: 00000002 00000000 00010000 0001 01 101 @\(name)" }

  @Test
  func pendingConnectionsBlockOnlyTheirListener() {
    let pending = "2: 00000002 00000000 00000000 0001 02 0 @\(name)"
    for snapshot in [listener + "\n" + pending, pending + "\n" + listener] {
      #expect(!ToolDiscovery.canOpenSocket(named: name, inProcNetUnix: snapshot))
    }
    let other = "2: 00000002 00000000 00000000 0001 02 0 @snapo_network_43"
    let accepted = "3: 00000002 00000000 00000000 0001 03 202 @\(name)"
    #expect(ToolDiscovery.canOpenSocket(named: name, inProcNetUnix: listener + "\n" + other + "\n" + accepted))
    for unavailable in ["", "cat: permission denied", pending, accepted] {
      #expect(!ToolDiscovery.canOpenSocket(named: name, inProcNetUnix: unavailable))
    }
  }

  @Test
  func retriesDoNotAddConnectionsUntilTheQueueDrains() async throws {
    let fixture = SocketQueue()
    let client = ADBClient(discoveryTimeout: .seconds(2), connectionFactory: fixture.connection)
    let serial = UUID().uuidString
    let first = try await client.openLocalAbstract(deviceID: serial, abstractSocket: name)
    first.close()
    for _ in 0 ..< 60 {
      await #expect(throws: ADBError.self) { try await client.openLocalAbstract(deviceID: serial, abstractSocket: name) }
    }
    #expect(fixture.opens == 1, "Closing a client does not drain Android's accept queue")
    fixture.drain()
    let second = try await client.openLocalAbstract(deviceID: serial, abstractSocket: name)
    second.close()
    #expect(fixture.opens == 2)
  }

  @Test
  func concurrentClientsShareAdmission() async {
    let fixture = SocketQueue()
    let serial = UUID().uuidString
    let admitted = await withTaskGroup(of: Bool.self) { group in
      for _ in 0 ..< 20 {
        group.addTask {
          let client = ADBClient(discoveryTimeout: .seconds(2), connectionFactory: fixture.connection)
          do {
            let connection = try await client.openLocalAbstract(deviceID: serial, abstractSocket: name)
            connection.close()
            return true
          } catch { return false }
        }
      }
      var count = 0
      for await success in group where success { count += 1 }
      return count
    }
    #expect(admitted == 1)
    #expect(fixture.opens == 1)
  }

  @Test
  func legacyProbesRespectTheSameQueue() async throws {
    let fixture = SocketQueue()
    let client = ADBClient(discoveryTimeout: .seconds(2), connectionFactory: fixture.connection)
    let serial = UUID().uuidString
    let first = try await client.openLocalAbstract(deviceID: serial, abstractSocket: name)
    first.close()
    let metadata = try await client.legacyPluginMetadata(deviceID: serial, socketName: name, kind: .network, pid: 42)
    #expect(metadata == nil)
    #expect(fixture.opens == 1)
  }

  @Test
  func cancellationReleasesAdmission() async throws {
    let serial = UUID().uuidString
    let blocked = ScriptedADBConnection(reads: [.waitForClose])
    let client = ADBClient(discoveryTimeout: .seconds(2)) { blocked }
    let task = Task { try await client.openLocalAbstract(deviceID: serial, abstractSocket: name) }
    defer { task.cancel(); blocked.close() }
    try await blocked.waitUntilBlocked()
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(blocked.isClosed)

    let fixture = SocketQueue()
    let replacement = ADBClient(discoveryTimeout: .seconds(2), connectionFactory: fixture.connection)
    let connection = try await replacement.openLocalAbstract(deviceID: serial, abstractSocket: name)
    connection.close()
    #expect(fixture.opens == 1)
  }

  @Test
  func serversWithTheSameSerialHaveIndependentQueues() async throws {
    let first = SocketQueue()
    let second = SocketQueue()
    let local = ADBClient(serverID: .local, connectionFactory: first.connection)
    let remote = ADBClient(serverID: .remote(UUID()), connectionFactory: second.connection)
    let serial = UUID().uuidString
    let one = try await local.openLocalAbstract(deviceID: serial, abstractSocket: name)
    let two = try await remote.openLocalAbstract(deviceID: serial, abstractSocket: name)
    one.close()
    two.close()
    #expect(first.opens == 1 && second.opens == 1)
  }
}

private final class SocketQueue: @unchecked Sendable {
  private let lock = NSLock()
  private var pending = false
  private var openCount = 0

  var opens: Int { lock.withLock { openCount } }

  func drain() { lock.withLock { pending = false } }

  func connection() -> any ADBConnection {
    let connection = ScriptedADBConnection(reads: [])
    connection.respond = { [weak connection, self] command in
      if command == "shell:cat /proc/net/unix" {
        let snapshot = lock.withLock {
          "1: 00000002 00000000 00010000 0001 01 101 @snapo_network_42\n"
            + (pending ? "2: 00000002 00000000 00000000 0001 02 0 @snapo_network_42\n" : "")
        }
        connection?.enqueue([.data(Data(snapshot.utf8)), .end])
      } else if command == "localabstract:snapo_network_42" {
        lock.withLock {
          openCount += 1
          pending = true
        }
      }
      return nil
    }
    return connection
  }
}
