import Foundation
@testable import Snap_O
import Testing

@MainActor
struct DeviceOpenResolverTests {
  @Test func opensExactConnectedSerialWithoutSDK() async throws {
    let resolver = DeviceOpenResolver {
      DeviceOpenSnapshot(connectedSerials: ["other-phone", "phone"], loadError: "SDK missing")
    } start: { _ in
      Issue.record("Opening a serial must not start an emulator")
    }
    let serial = try await resolver.resolve(.serial("phone")) { _ in }
    #expect(serial == "phone")
  }

  @Test func reusesRunningEmulator() async throws {
    let resolver = DeviceOpenResolver {
      DeviceOpenSnapshot(
        connectedSerials: ["emulator-5556"],
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
          state.connectedSerials = ["emulator-5558"]
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
        state.connectedSerials = ["emulator-5554"]
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
          connectedSerials: ["emulator-5554"],
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
            connectedSerials: ["emulator-5554"],
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
          connectedSerials: ["emulator-5554"],
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
        state.connectedSerials = ["emulator-5556"]
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
        DeviceOpenSnapshot(connectedSerials: ["other-phone"], emulators: devices, hasLoaded: true)
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

  @Test func unavailableTargetTimesOutWithoutSelectingAnother() async {
    let resolver = DeviceOpenResolver(
      snapshot: { DeviceOpenSnapshot(connectedSerials: ["other-phone"]) },
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
      snapshot: { DeviceOpenSnapshot() },
      start: { _ in Issue.record("Unexpected launch") },
      wait: { try await suspension.wait() }
    )
    let task = Task { try await resolver.resolve(.serial("phone")) { _ in } }
    await suspension.waitUntilStarted()
    task.cancel()
    suspension.resume()
    await #expect(throws: CancellationError.self) { try await task.value }
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
