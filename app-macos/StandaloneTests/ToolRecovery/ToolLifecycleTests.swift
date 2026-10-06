import Foundation

@MainActor
struct ToolLifecycleTests {
  static func run() async throws {
    try await joinsSupersededLaunch()
    try await restartRetainsOldDiscoveryCleanup()
    try await hostJoinsReplacedPage()
    try await hostJoinsSupersededBindings()
    try await sessionJoinsModelAndService()
  }

  private static func preferences() -> UserDefaults {
    guard let preferences = UserDefaults(suiteName: "SnapOToolLifecycle-" + UUID().uuidString) else {
      preconditionFailure("Cannot create test preferences")
    }
    return preferences
  }

  private static func app(_ pid: Int) -> InspectableApp {
    InspectableApp(
      id: "healthy:pid:\(pid)", pid: pid, deviceId: "healthy", deviceDisplayTitle: "Phone",
      tools: [AppToolOption(
        kind: .network, server: .init(deviceId: "healthy", socketName: "snapo_network_\(pid)"),
        isConnected: true, compatibility: .supported
      )], metadata: testProcessMetadata(pid: pid, kinds: [.network])
    )
  }

  private static func joinsSupersededLaunch() async throws {
    let first = app(42)
    let second = app(43)
    let gate = TestGate()
    let model = AppToolModel(
      preferences: preferences(), discover: { ToolDiscoverySnapshot(apps: [first, second]) },
      openApp: { _ in await gate.wait() }
    )
    await model.start()?.value
    model.selectApp(first)
    _ = model.openSelectedApp(appId: first.id)
    try await ToolRecoveryTests.eventually { await gate.waitCount == 1 }
    model.selectApp(second)
    let stopped = TestValue(false)
    let cleanup = model.stop()
    let waiter = await startTestTask {
      await cleanup.value
      stopped.value = true
    }
    precondition(!stopped.value, "The superseded launch still belongs to the model")
    await gate.open()
    await waiter.value
    precondition(model.snapshot.state.selectedApp?.id == second.id)
    print("Tool model shutdown joins a launch canceled by a different app selection")
  }

  private static func restartRetainsOldDiscoveryCleanup() async throws {
    let gate = TestGate()
    var scans = 0
    let model = AppToolModel(
      preferences: preferences(), discover: {
        scans += 1
        let scan = scans
        if scan == 1 { await gate.wait() }
        return ToolDiscoverySnapshot(apps: [app(scan == 1 ? 42 : 43)])
      }, openApp: { _ in }
    )
    _ = model.start()
    try await ToolRecoveryTests.eventually { await gate.waitCount == 1 }
    let firstCleanup = model.stop()
    await model.start()?.value
    precondition(model.snapshot.state.selectedApp?.id == app(43).id)
    let stopped = TestValue(false)
    let secondCleanup = model.stop()
    let waiter = await startTestTask {
      await secondCleanup.value
      stopped.value = true
    }
    precondition(!stopped.value, "Restart must not lose the earlier canceled scan")
    await gate.open()
    await firstCleanup.value
    await waiter.value
    precondition(model.snapshot.state.selectedApp?.id == app(43).id)
    print("Tool model can restart while retaining old discovery through final cleanup")
  }

  private static func configure(_ adbService: ADBService) async -> DeviceManager {
    let adb = await adbService.exec()
    adb.setMetadataAvailable(true)
    adb.setSocketNames(["snapo_network_42"], deviceID: "healthy")
    let target = DeviceTarget(serial: "healthy", transportID: "1")
    return DeviceManager(devices: [Device(
      id: "healthy", model: "Phone", androidVersion: "Test", vendorModel: nil,
      manufacturer: nil, avdName: nil, connection: target
    )])
  }

  private static func hostJoinsReplacedPage() async throws {
    let adbService = ADBService()
    let devices = await configure(adbService)
    let adb = await adbService.exec()
    let frontend = TestGate()
    adb.setProbeGate(frontend, for: .frontend)
    let service = ToolService(adbService: adbService, deviceManager: devices)
    let model = ToolHostModel(service: service, preferences: preferences())
    try await ToolRecoveryTests.eventually { await frontend.waitCount == 1 }
    guard let original = model.webContainer as? ToolWebContainer else { preconditionFailure("Missing original page") }
    let pageCleanup = TestGate()
    original.cleanupGate = pageCleanup
    model.retryFrontend()
    guard let replacement = model.webContainer as? ToolWebContainer else { preconditionFailure("Missing replacement page") }
    precondition(original !== replacement && original.isStopped)
    let cleanup = model.stop()
    precondition(cleanup == model.stop(), "Repeated model stop shares one cleanup task")
    let stopped = TestValue(false)
    let waiter = await startTestTask {
      await cleanup.value
      stopped.value = true
    }
    precondition(!stopped.value && replacement.isStopped)
    await frontend.open()
    try await ToolRecoveryTests.eventually { await pageCleanup.waitCount == 1 }
    precondition(!stopped.value, "Frontend completion must still join page cleanup")
    await pageCleanup.open()
    await waiter.value
    await service.stop()
    precondition(original.didFinishStopping && replacement.didFinishStopping)
    precondition(!original.didStart && !replacement.didStart && model.webContainer == nil)
    print("Tool host shutdown joins superseded frontend work and every page cleanup")
  }

  private static func hostJoinsSupersededBindings() async throws {
    let adbService = ADBService()
    let devices = await configure(adbService)
    let service = ToolService(adbService: adbService, deviceManager: devices)
    let model = ToolHostModel(service: service, preferences: preferences())
    try await ToolRecoveryTests.eventually { (model.webContainer as? ToolWebContainer)?.didStart == true }
    guard let page = model.webContainer as? ToolWebContainer else { preconditionFailure("Missing tool page") }
    let binding = TestGate()
    await adbService.setExecutionGate(binding)
    page.pageReadinessChangedHandler?(true)
    try await ToolRecoveryTests.eventually { await binding.waitCount == 1 }
    page.pageReadinessChangedHandler?(true)
    try await ToolRecoveryTests.eventually { await binding.waitCount == 2 }
    let stopped = TestValue(false)
    let cleanup = model.stop()
    let waiter = await startTestTask {
      await cleanup.value
      stopped.value = true
    }
    precondition(!stopped.value, "Current and superseded endpoint lookups must finish")
    let serverUpdates = page.serverUpdates
    await binding.open()
    await waiter.value
    await service.stop()
    precondition(page.serverUpdates == serverUpdates, "Stopped lookups cannot bind a page")
    print("Tool host shutdown joins current and superseded endpoint lookups")
  }

  private static func sessionJoinsModelAndService() async throws {
    let adbService = ADBService()
    let devices = await configure(adbService)
    let adb = await adbService.exec()
    let frontend = TestGate()
    adb.setProbeGate(frontend, for: .frontend)
    let session = ToolSession(adbService: adbService, deviceManager: devices)
    session.startIfNeeded()
    try await ToolRecoveryTests.eventually { await frontend.waitCount == 1 }
    guard let page = session.model?.webContainer as? ToolWebContainer else { preconditionFailure("Missing session page") }
    let firstFinished = TestValue(false)
    let first = await startTestTask {
      await session.stop()
      firstFinished.value = true
    }
    precondition(session.model == nil && page.isStopped && !firstFinished.value)
    session.startIfNeeded()
    precondition(session.model == nil, "A closed workspace cannot restart its tool session")
    let secondFinished = TestValue(false)
    let second = await startTestTask {
      await session.stop()
      secondFinished.value = true
    }
    precondition(!secondFinished.value)
    await frontend.open()
    await first.value
    await second.value
    precondition(firstFinished.value && secondFinished.value && page.didFinishStopping)
    precondition(!page.didStart)
    print("Tool session joins model and service shutdown and rejects restart after closure")
  }
}
