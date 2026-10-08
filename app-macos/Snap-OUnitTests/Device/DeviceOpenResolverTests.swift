import Foundation
import Testing

@MainActor
struct DeviceOpenResolverTests {
  @Test func opensExactConnectedSerialWithoutSDK() async throws {
    let resolver = DeviceOpenResolver {
      DeviceOpenSnapshot(connectedDeviceIDs: ["other-phone", "phone"], servers: [.local: connected(.local())], loadError: "SDK missing")
    } start: { _ in
      Issue.record("Opening a serial must not start an emulator")
    }
    let serial = try await resolver.resolve(.serial("phone")) { _ in }
    #expect(serial == "phone")
  }

  @Test func selectsExistingConnectionByDestinationAndPorts() async throws {
    let first = DeviceID(serverID: .remote(UUID()), serial: "phone")
    let second = DeviceID(serverID: .remote(UUID()), serial: "phone")
    let third = DeviceID(serverID: .remote(UUID()), serial: "phone")
    let resolver = DeviceOpenResolver(snapshot: {
      DeviceOpenSnapshot(
        connectedDeviceIDs: ["phone", first.storedValue, second.storedValue, third.storedValue],
        servers: [
          .local: connected(.local()),
          first.serverID: connected(.ssh(destination: "test-host", port: 2222, adbPort: 5038)),
          second.serverID: connected(.ssh(destination: "test-host", port: 2223, adbPort: 5038)),
          third.serverID: connected(.ssh(destination: "test-host", port: 2222, adbPort: 5037))
        ]
      )
    }, start: { _ in Issue.record("A connection selector must not launch an emulator") }, wait: {
      Issue.record("A connection selector must not wait for another connection")
      throw CancellationError()
    })
    let url = try #require(URL(string: "snapo://open?serial=phone&server=test-host&port=2223&adb_port=5038"))
    let link = try #require(DeviceOpenURL(url: url))
    guard case .target(let request) = link else {
      Issue.record("Expected a device target")
      return
    }
    #expect(try await resolver.resolve(request) { _ in } == second.storedValue)
    #expect(try await resolver.resolve(.serial("phone", server: .ssh(destination: "test-host"))) { _ in } == third.storedValue)
    #expect(try await resolver.resolve(.serial("phone")) { _ in } == "phone")
    await #expect(throws: DeviceOpenError.self) {
      try await resolver.resolve(.serial("phone", server: .ssh(destination: "test-host", adbPort: 5038))) { _ in }
    }
  }

  @Test(arguments: [
    DeviceLinkServer.local(adbPort: 5038),
    .ssh(destination: "unknown-host"),
    .ssh(destination: "test-host", port: 2223),
    .ssh(destination: "test-host", adbPort: 5038)
  ])
  func missingConnectionsFailWithoutWaiting(server: DeviceLinkServer) async {
    let id = DeviceID(serverID: .remote(UUID()), serial: "phone")
    let resolver = DeviceOpenResolver(snapshot: {
      DeviceOpenSnapshot(
        connectedDeviceIDs: ["phone", id.storedValue],
        servers: [.local: connected(.local()), id.serverID: connected(.ssh(destination: "test-host", port: 2222))]
      )
    }, start: { _ in Issue.record("A missing server must not launch an emulator") }, wait: {
      Issue.record("A missing server must not wait for a new connection")
      throw CancellationError()
    })
    await #expect(throws: DeviceOpenError.self) {
      try await resolver.resolve(.serial("phone", server: server)) { _ in }
    }
  }

  @Test func disconnectedServerDoesNotUseStaleDeviceInventory() async {
    let id = DeviceID(serverID: .remote(UUID()), serial: "phone")
    let resolver = DeviceOpenResolver(snapshot: {
      DeviceOpenSnapshot(connectedDeviceIDs: [id.storedValue])
    }, start: { _ in Issue.record("A disconnected server must not launch an emulator") })
    await #expect(throws: DeviceOpenError.self) {
      try await resolver.resolve(.serial("phone", server: .ssh(destination: "test-host"))) { _ in }
    }
  }

  @Test func unqualifiedLinkDoesNotFallBackToRemoteServer() async {
    let id = DeviceID(serverID: .remote(UUID()), serial: "phone")
    let resolver = DeviceOpenResolver(snapshot: {
      DeviceOpenSnapshot(
        connectedDeviceIDs: [id.storedValue],
        servers: [id.serverID: connected(.ssh(destination: "test-host"))]
      )
    }, start: { _ in Issue.record("A serial link must not launch an emulator") })
    await #expect(throws: DeviceOpenError.self) {
      try await resolver.resolve(.serial("phone")) { _ in }
    }
  }

  @Test func reusesRunningEmulator() async throws {
    let resolver = DeviceOpenResolver {
      DeviceOpenSnapshot(
        connectedDeviceIDs: ["emulator-5556"],
        emulators: [emulator(state: .running, serial: "emulator-5556")],
        hasLoaded: true
      )
    } start: { _ in
      Issue.record("A running emulator must not be started again")
    }
    let serial = try await resolver.resolve(.avd("Pixel", start: true)) { _ in }
    #expect(serial == "emulator-5556")
  }

  @Test func startsOnceAndOpensBeforeBootCompletes() async throws {
    var state = DeviceOpenSnapshot(emulators: [emulator()], hasLoaded: true)
    var starts = 0
    var waits = 0
    var progress: [String] = []
    let resolver = DeviceOpenResolver(
      snapshot: { state },
      start: { device in
        starts += 1
        #expect(device.id == "/synthetic/Pixel.avd")
        state.actions[device.id] = "Starting"
      },
      wait: {
        waits += 1
        switch waits {
        case 1:
          break // The launch request is still in flight.
        case 2:
          state.actions = [:]
          state.emulators = [emulator(state: .starting, serial: "emulator-5558")]
          state.connectedDeviceIDs = ["emulator-5558"]
        default:
          state.emulators = [emulator(state: .running, serial: "emulator-5558")]
        }
      }
    )
    let serial = try await resolver.resolve(.avd("Pixel", start: true)) { progress.append($0) }
    #expect(serial == "emulator-5558")
    #expect(starts == 1)
    #expect(waits == 2)
    #expect(progress.contains("Starting"))
    #expect(state.emulators.first?.state == .starting)
  }

  @Test func waitsForExistingLaunchWithoutStartingAgain() async throws {
    var state = DeviceOpenSnapshot(emulators: [emulator(state: .starting)], hasLoaded: true)
    let resolver = DeviceOpenResolver(
      snapshot: { state },
      start: { _ in Issue.record("A booting emulator must not be started again") },
      wait: {
        state.emulators = [emulator(state: .starting, serial: "emulator-5554")]
        state.connectedDeviceIDs = ["emulator-5554"]
      }
    )
    let serial = try await resolver.resolve(.avd("Pixel", start: false)) { _ in }
    #expect(serial == "emulator-5554")
  }

  @Test(arguments: [ManagedEmulator.State.starting, .offline])
  func opensConnectedBootingEmulator(state: ManagedEmulator.State) async throws {
    let resolver = DeviceOpenResolver(
      snapshot: {
        DeviceOpenSnapshot(
          connectedDeviceIDs: ["emulator-5554"],
          emulators: [emulator(state: state, serial: "emulator-5554")],
          hasLoaded: true
        )
      },
      start: { _ in Issue.record("A connected emulator must not be started again") },
      timeout: .zero
    )
    let serial = try await resolver.resolve(.avd("Pixel", start: false)) { _ in }
    #expect(serial == "emulator-5554")
  }

  @Test func rejectsBusyConnectedEmulator() async {
    for (state, action): (ManagedEmulator.State, String?) in [(.stopping, nil), (.running, "Deleting")] {
      let resolver = DeviceOpenResolver(
        snapshot: {
          DeviceOpenSnapshot(
            connectedDeviceIDs: ["emulator-5554"],
            emulators: [emulator(state: state, serial: "emulator-5554")],
            hasLoaded: true,
            actions: action.map { ["/synthetic/Pixel.avd": $0] } ?? [:]
          )
        },
        start: { _ in Issue.record("A busy emulator must not be started") },
        timeout: .zero
      )
      await expectFailure("“Pixel” is busy. Try again after its current action finishes.") {
        try await resolver.resolve(.avd("Pixel", start: true)) { _ in }
      }
    }
  }

  @Test func waitsForInitialInventory() async throws {
    var state = DeviceOpenSnapshot()
    let resolver = DeviceOpenResolver(
      snapshot: { state },
      start: { _ in Issue.record("Unexpected launch") },
      wait: {
        state = DeviceOpenSnapshot(
          connectedDeviceIDs: ["emulator-5554"],
          emulators: [emulator(state: .running, serial: "emulator-5554")],
          hasLoaded: true
        )
      }
    )
    let serial = try await resolver.resolve(.avd("Pixel", start: false)) { _ in }
    #expect(serial == "emulator-5554")
  }

  @Test func waitsForRunningEmulatorToBeMatchedBeforeLaunching() async throws {
    var state = DeviceOpenSnapshot(emulators: [emulator()], hasLoaded: true, isRefreshing: true)
    let resolver = DeviceOpenResolver(
      snapshot: { state },
      start: { _ in Issue.record("Inventory refresh is still matching the running emulator") },
      wait: {
        state.isRefreshing = false
        state.emulators = [emulator(state: .running, serial: "emulator-5556")]
        state.connectedDeviceIDs = ["emulator-5556"]
      }
    )
    let serial = try await resolver.resolve(.avd("Pixel", start: true)) { _ in }
    #expect(serial == "emulator-5556")
  }

  @Test func reportsLaunchFailureWithoutRetrying() async {
    var state = DeviceOpenSnapshot(emulators: [emulator()], hasLoaded: true)
    var starts = 0
    let resolver = DeviceOpenResolver(
      snapshot: { state },
      start: { device in
        starts += 1
        state.actions[device.id] = "Starting"
      },
      wait: {
        state.actions = [:]
        state.launchErrors["/synthetic/Pixel.avd"] = "Synthetic launch failure"
      }
    )
    await expectFailure("Synthetic launch failure") {
      try await resolver.resolve(.avd("Pixel", start: true)) { _ in }
    }
    #expect(starts == 1)
  }

  @Test func rejectsMissingAndAmbiguousAVDs() async {
    for devices in [[], [emulator(), emulator()]] {
      let resolver = DeviceOpenResolver {
        DeviceOpenSnapshot(connectedDeviceIDs: ["other-phone"], emulators: devices, hasLoaded: true)
      } start: { _ in Issue.record("Invalid targets must not launch") }
      await #expect(throws: DeviceOpenError.self) {
        try await resolver.resolve(.avd("Pixel", start: true)) { _ in }
      }
    }
  }

  @Test func requiresExplicitStartup() async {
    let resolver = DeviceOpenResolver {
      DeviceOpenSnapshot(emulators: [emulator()], hasLoaded: true)
    } start: { _ in Issue.record("Startup was not requested") }
    await #expect(throws: DeviceOpenError.self) {
      try await resolver.resolve(.avd("Pixel", start: false)) { _ in }
    }
  }

  @Test func unavailableTargetFailsWithoutSelectingAnother() async {
    let resolver = DeviceOpenResolver(
      snapshot: { DeviceOpenSnapshot(connectedDeviceIDs: ["other-phone"], servers: [.local: connected(.local())]) },
      start: { _ in Issue.record("Unexpected launch") },
      timeout: .zero
    )
    await #expect(throws: DeviceOpenError.self) {
      try await resolver.resolve(.serial("missing-phone")) { _ in }
    }
  }

  @Test func cancellationStopsWaiting() async {
    let suspension = TestSuspension()
    let resolver = DeviceOpenResolver(
      snapshot: { DeviceOpenSnapshot(servers: [.local: DeviceLinkConnection(server: .local())]) },
      start: { _ in Issue.record("Unexpected launch") },
      wait: { try await suspension.wait() }
    )
    let task = Task { try await resolver.resolve(.serial("phone")) { _ in } }
    await suspension.waitUntilStarted()
    task.cancel()
    suspension.resume()
    await #expect(throws: CancellationError.self) { try await task.value }
  }

  @Test(arguments: [DeviceLinkServer.local(), .ssh(destination: "test-host", port: 2222)])
  func waitsForNormalStartupDiscovery(server: DeviceLinkServer) async throws {
    let id = DeviceID(serverID: server == .local() ? .local : .remote(UUID()), serial: "phone")
    var state = DeviceOpenSnapshot(servers: [id.serverID: DeviceLinkConnection(server: server)])
    var waits = 0
    let resolver = DeviceOpenResolver(snapshot: { state }, start: { _ in
      Issue.record("Startup discovery must not launch an emulator")
    }, wait: {
      waits += 1
      switch waits {
      case 1: state.servers[id.serverID]?.state = .online
      case 2: state.servers[id.serverID]?.connectedSerials = ["phone"]
      case 3: state.connectedDeviceIDs = [id.storedValue]
      default: Issue.record("Discovery should have finished")
        throw CancellationError()
      }
    })
    #expect(try await resolver.resolve(.serial("phone", server: server)) { _ in } == id.storedValue)
    #expect(waits == 3)
  }

  @Test func startupStillUsesTheExistingTimeout() async {
    let resolver = DeviceOpenResolver(snapshot: {
      DeviceOpenSnapshot(servers: [.local: DeviceLinkConnection(server: .local())])
    }, start: { _ in Issue.record("Unexpected launch") }, wait: {
      Issue.record("An expired deadline must not sleep")
    }, timeout: .zero)
    await expectFailure("“phone” did not become available. Check Device Manager and try again.") {
      try await resolver.resolve(.serial("phone")) { _ in }
    }
  }

  @Test
  func approvedServerDoesNotSwitchToAnotherMatch() async {
    let approvedID = ADBServerID.remote(UUID())
    let otherID = ADBServerID.remote(UUID())
    let server = DeviceLinkServer.ssh(destination: "test-host", port: 2222)
    let resolver = DeviceOpenResolver(snapshot: {
      DeviceOpenSnapshot(servers: [otherID: connected(server, serials: ["phone"])])
    }, start: { _ in Issue.record("Unexpected launch") })
    await expectFailure("The selected ADB server disconnected while opening the device.") {
      try await resolver.resolve(.serial("phone", server: server, serverID: approvedID)) { _ in }
    }
  }

  @Test func serverErrorsAreDistinct() async {
    let cases: [(DeviceLinkConnection?, String)] = [
      (nil, "No configured ADB server matches this link."),
      (DeviceLinkConnection(server: .local(), isEnabled: false), "The matching ADB server is disabled."),
      (
        DeviceLinkConnection(server: .local(), state: .unavailable("Connection refused")),
        "ADB server connection failed: Connection refused"
      ),
      (connected(.local(), serials: []), "“phone” is not connected to the selected ADB server.")
    ]
    for (connection, expected) in cases {
      let resolver = DeviceOpenResolver(snapshot: {
        DeviceOpenSnapshot(servers: connection.map { [.local: $0] } ?? [:])
      }, start: { _ in Issue.record("Unexpected launch") }, wait: {
        Issue.record("A terminal failure must not wait")
        throw CancellationError()
      })
      await expectFailure(expected) { try await resolver.resolve(.serial("phone")) { _ in } }
    }
  }

  @Test func ambiguousStartupDoesNotPreferWhicheverServerLoadsFirst() async {
    let pendingID = ADBServerID.remote(UUID())
    let readyID = ADBServerID.remote(UUID())
    let readyDevice = DeviceID(serverID: readyID, serial: "phone")
    let resolver = DeviceOpenResolver(snapshot: {
      DeviceOpenSnapshot(connectedDeviceIDs: [readyDevice.storedValue], servers: [
        pendingID: DeviceLinkConnection(server: .ssh(destination: "test-host", port: 2222)),
        readyID: connected(.ssh(destination: "test-host", port: 2223))
      ])
    }, start: { _ in Issue.record("Unexpected launch") })
    await expectFailure("More than one enabled ADB server matches this link. Specify its SSH port.") {
      try await resolver.resolve(.serial("phone", server: .ssh(destination: "test-host"))) { _ in }
    }
  }

  @Test func waitingRequestKeepsItsServerWhenAnotherMatchAppears() async throws {
    let first = DeviceID(serverID: .remote(UUID()), serial: "phone")
    let second = DeviceID(serverID: .remote(UUID()), serial: "phone")
    var state = DeviceOpenSnapshot(servers: [first.serverID: DeviceLinkConnection(server: .ssh(destination: "test-host", port: 2222))])
    var waits = 0
    let resolver = DeviceOpenResolver(snapshot: { state }, start: { _ in Issue.record("Unexpected launch") }, wait: {
      waits += 1
      if waits == 1 {
        state.servers[second.serverID] = connected(.ssh(destination: "test-host", port: 2223))
        state.connectedDeviceIDs = [second.storedValue]
      } else {
        state.servers[first.serverID] = connected(.ssh(destination: "test-host", port: 2222))
        state.connectedDeviceIDs.insert(first.storedValue)
      }
    })
    #expect(try await resolver.resolve(.serial("phone", server: .ssh(destination: "test-host"))) { _ in } == first.storedValue)
    #expect(waits == 2)
  }

  @Test(arguments: ["removed", "disabled", "changed", "failed", "disconnected"])
  func waitingRequestDoesNotSwitchServersAfterConnectionLoss(change: String) async {
    let first = DeviceID(serverID: .remote(UUID()), serial: "phone")
    let second = DeviceID(serverID: .remote(UUID()), serial: "phone")
    var state = DeviceOpenSnapshot(servers: [first.serverID: DeviceLinkConnection(server: .ssh(destination: "test-host"), state: .online)])
    var waits = 0
    let resolver = DeviceOpenResolver(snapshot: { state }, start: { _ in Issue.record("Unexpected launch") }, wait: {
      waits += 1
      guard waits == 1 else { Issue.record("A lost connection must not keep waiting")
        throw CancellationError()
      }
      state.servers[second.serverID] = connected(.ssh(destination: "test-host"))
      state.connectedDeviceIDs = [second.storedValue]
      switch change {
      case "removed": state.servers[first.serverID] = nil
      case "disabled": state.servers[first.serverID]?.isEnabled = false
      case "changed": state.servers[first.serverID]?.server = .ssh(destination: "other-host")
      case "failed": state.servers[first.serverID]?.state = .unavailable("Connection lost")
      default: state.servers[first.serverID]?.state = .connecting
      }
    })
    await #expect(throws: DeviceOpenError.self) {
      try await resolver.resolve(.serial("phone", server: .ssh(destination: "test-host"))) { _ in }
    }
    #expect(waits == 1)
  }

  @Test func replacementDoesNotCompleteTheCancelledWait() async throws {
    let gate = TestSuspension()
    var state = DeviceOpenSnapshot(servers: [.local: DeviceLinkConnection(server: .local())])
    let resolver = DeviceOpenResolver(snapshot: { state }, start: { _ in Issue.record("Unexpected launch") }, wait: {
      try await gate.wait()
    })
    let first = Task { try await resolver.resolve(.serial("first")) { _ in } }
    await gate.waitUntilStarted()
    first.cancel()
    state = DeviceOpenSnapshot(
      connectedDeviceIDs: ["first", "second"],
      servers: [.local: connected(.local(), serials: ["first", "second"])]
    )
    #expect(try await resolver.resolve(.serial("second")) { _ in } == "second")
    gate.resume()
    await #expect(throws: CancellationError.self) { try await first.value }
  }

  private func connected(_ server: DeviceLinkServer, serials: Set<String> = ["phone"]) -> DeviceLinkConnection {
    DeviceLinkConnection(server: server, state: .online, connectedSerials: serials)
  }

  private func expectFailure(_ message: String, operation: () async throws -> String) async {
    do {
      _ = try await operation()
      Issue.record("Expected an error")
    } catch {
      #expect(error.localizedDescription == message)
    }
  }

  private func emulator(
    state: ManagedEmulator.State = .stopped,
    serial: String? = nil
  ) -> ManagedEmulator {
    ManagedEmulator(
      id: "/synthetic/Pixel.avd", avdName: "Pixel", title: "Pixel",
      platform: "Android 15", architecture: "arm64", state: state, serial: serial
    )
  }
}
