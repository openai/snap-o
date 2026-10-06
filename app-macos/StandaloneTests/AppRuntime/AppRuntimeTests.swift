import Clocks
import ConcurrencyExtras
import Dependencies
import Foundation

@main
@MainActor
struct AppRuntimeTests {
  private static let consumers: Set<ShutdownProbe.Owner> = [.startup, .workspaces, .manager, .preview]

  static func main() async throws {
    try await withMainSerialExecutor {
      try await withDependencies {
        $0.context = .test
        $0.continuousClock = TestClock()
      } operation: {
        try await AppTerminationTests.run()
        await startupUsesCurrentSettingsAndDevices()
        await managerShutdownStopsStartupPreparation()
        for held in consumers.union([.reservations]) {
          await shutdownPreservesTargets(until: held)
        }
        for restoring in [false, true] {
          try await deadlineReportsDependentCleanup(restoring: restoring)
        }
      }
    }
    print("App runtime startup and shutdown tests passed")
  }

  private static func startupUsesCurrentSettingsAndDevices() async {
    let probe = ShutdownProbe()
    RuntimeTestEnvironment.probe = probe
    let settings = AppSettings.shared
    settings.startupCaptureMode = .livePreview
    settings.showTouchesDuringCapture = false
    settings.lastViewedDeviceID = nil
    let runtime = AppRuntime()
    let first = device("first")
    let preferred = device("preferred")
    runtime.deviceManager.inventory.connected = [first, preferred]
    settings.lastViewedDeviceID = preferred.id
    runtime.start()
    await waitForObservedTestState { probe.startupRequests.value.last?.devices == [preferred] }
    precondition(runtime.deviceManager.inventory.ready == nil, "Preview preparation must precede Android readiness")
    let count = probe.startupRequests.value.count
    runtime.start()
    precondition(probe.startupRequests.value.count == count)

    settings.lastViewedDeviceID = first.id
    await waitForObservedTestState { probe.startupRequests.value.last?.devices == [first] }
    settings.lastViewedDeviceID = "missing"
    await waitForObservedTestState { probe.startupRequests.value.count > count + 1 }
    precondition(probe.startupRequests.value.last?.devices == [first], "Missing preferences fall back to the first connection")

    settings.startupCaptureMode = .screenshot
    await waitForObservedTestState {
      probe.startupRequests.value.last?.mode == .screenshot
    }
    precondition(probe.startupRequests.value.last?.devices.isEmpty == true, "Connected devices cannot authorize screenshots")
    runtime.deviceManager.inventory.ready = [first, preferred]
    await waitForObservedTestState { probe.startupRequests.value.last?.devices == [first, preferred] }

    let replacement = device(first.id)
    runtime.deviceManager.inventory = DeviceInventory(connected: [replacement], ready: [replacement])
    await waitForObservedTestState { probe.startupRequests.value.last?.devices == [replacement] }
    runtime.deviceManager.inventory.ready = []
    await waitForObservedTestState { probe.startupRequests.value.last?.devices.isEmpty == true }
    await runtime.shutdown()
    let stoppedCount = probe.startupRequests.value.count
    runtime.start()
    precondition(probe.startupRequests.value.count == stoppedCount, "Shutdown must prevent another startup")
    settings.startupCaptureMode = .livePreview
    settings.showTouchesDuringCapture = false
    settings.lastViewedDeviceID = nil
  }

  private static func managerShutdownStopsStartupPreparation() async {
    let probe = ShutdownProbe()
    RuntimeTestEnvironment.probe = probe
    let runtime = AppRuntime()
    runtime.start()
    await waitForObservedTestState { !probe.startupRequests.value.isEmpty }
    await runtime.deviceManager.shutdown().value
    let count = probe.startupRequests.value.count
    runtime.deviceManager.inventory.connected = [device("late")]
    AppSettings.shared.showTouchesDuringCapture.toggle()
    await runtime.shutdown()
    precondition(probe.startupRequests.value.count == count, "Manager shutdown must stop preparation without cancelling its observer")
    AppSettings.shared.showTouchesDuringCapture = false
  }

  private static func device(_ id: String) -> Device {
    Device(
      id: id, model: "Test", androidVersion: "16", vendorModel: nil,
      manufacturer: nil, avdName: nil, connection: DeviceTarget(serial: id, transportID: "1")
    )
  }

  private static func prepare(_ probe: ShutdownProbe, runtime: AppRuntime) async {
    for owner: ShutdownProbe.Owner in [.startup, .workspaces, .preview] {
      probe.leases[owner] = await ShowTouchesOverride.apply(target: probe.target, enabled: true, using: runtime.adbService)
    }
    precondition(probe.showsTouches)
  }

  private static func shutdownPreservesTargets(until held: ShutdownProbe.Owner) async {
    let probe = ShutdownProbe()
    RuntimeTestEnvironment.probe = probe
    let runtime = AppRuntime()
    await prepare(probe, runtime: runtime)
    let consumer = TestGate()
    let files = TestGate()
    let history = TestGate()
    probe.gates = [held: consumer, .files: files, .history: history]
    let firstFinished = TestValue(false)
    let first = await startTestTask {
      await runtime.shutdown()
      firstFinished.value = true
    }
    await waitForActorTestState { await consumer.waitCount == 1 }
    await waitForActorTestState { consumers.subtracting([held]).isSubset(of: probe.finished) }
    precondition(probe.admissionClosed && probe.exportsClosed)
    precondition(!probe.started.contains(.tracker) && probe.target.isValid, "Keep connections alive through consumer cleanup")
    precondition(!probe.started.contains(.files) && !probe.started.contains(.history))
    precondition(runtime.unfinishedCleanup.contains("device tracking"))
    let repeatedFinished = TestValue(false)
    let repeated = await startTestTask {
      await runtime.shutdown()
      repeatedFinished.value = true
    }
    precondition(!firstFinished.value && !repeatedFinished.value)
    await consumer.open()
    await waitForActorTestState { await files.waitCount == 1 }
    precondition(consumers.isSubset(of: probe.finished) && probe.finished.contains(.tracker))
    precondition(probe.finished.contains(.reservations) && !probe.target.isValid)
    precondition(probe.invalidTargets.isEmpty && !probe.showsTouches, "Restore real touch-setting leases before invalidation")
    precondition(!probe.started.contains(.history))
    await files.open()
    await waitForActorTestState { await history.waitCount == 1 }
    precondition(probe.finished.contains(.files) && !firstFinished.value && !repeatedFinished.value)
    await history.open()
    await first.value
    await repeated.value
    precondition(probe.finished == Set(ShutdownProbe.Owner.allCases) && runtime.unfinishedCleanup.isEmpty)
  }

  private static func deadlineReportsDependentCleanup(restoring: Bool) async throws {
    let clock = TestClock()
    try await withDependencies { $0.continuousClock = clock } operation: {
      let probe = ShutdownProbe()
      RuntimeTestEnvironment.probe = probe
      let runtime = AppRuntime()
      let gate = TestGate()
      if restoring {
        probe.leases[.workspaces] = await ShowTouchesOverride.apply(
          target: probe.target, enabled: true, using: runtime.adbService
        )
        probe.restorationGate = gate
      } else {
        await prepare(probe, runtime: runtime)
        probe.gates[.workspaces] = gate
      }
      let termination = AppTermination()
      let replies = TestValue<[AppTermination.Outcome]>([])
      termination.begin { await runtime.shutdown() } unfinishedWork: {
        runtime.unfinishedCleanup
      } reply: { replies.value.append($0) }
      await waitForActorTestState { await gate.waitCount == 1 }
      await waitForActorTestState { consumers.subtracting([.workspaces]).isSubset(of: probe.finished) }
      await clock.advance(by: .seconds(5))
      await waitForObservedTestState { !replies.value.isEmpty }
      let unfinished = ["device tracking", "workspaces", "capture reservations", "file exports", "History"]
      guard case .timedOut(let pending) = replies.value.first else {
        preconditionFailure("Expected the termination deadline to report unfinished cleanup")
      }
      precondition(Set(pending) == Set(unfinished))
      precondition(probe.target.isValid, "Timing out must not invalidate resources needed by late cleanup")
      await gate.open()
      await runtime.shutdown()
      precondition(probe.invalidTargets.isEmpty && !probe.showsTouches)
      precondition(runtime.unfinishedCleanup.isEmpty && replies.value.count == 1)
      try await clock.checkSuspension()
    }
  }
}
