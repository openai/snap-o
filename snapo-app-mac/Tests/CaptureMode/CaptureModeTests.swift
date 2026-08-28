import Foundation

@MainActor
final class MediaDisplayMode {
  func updateMediaList(_: [CaptureMedia], preserveDeviceID _: String?, shouldSort _: Bool) {}
}

@main
@MainActor
struct CaptureModeTests {
  static let options = LivePreviewOptions(showsTouches: false)
  static let first = testDevice("first")
  static let second = testDevice("second")

  static func main() async throws {
    try await teardownWaitsForPointerPreparation()
    try await removingDevicePreservesOtherPointer()
    try await pointerWaitsForReadiness()
    try await failedStreamsDoNotPreparePointer()
    try await stoppedPreviewDoesNotPreparePointer()
    try await removedDeviceDoesNotPreparePointer()
    try await stoppedRendererIgnoresLateReadiness()
    try await replacedRendererCannotSendPointer()
    try await stopWaitsForRendererCleanup()
    await stopDuringRendererStart()
    await overlappingDeviceUpdates()
    await modePropagatesCancellation()
    print("Capture mode tests passed (12 cases)")
  }

  static func eventually(_ condition: () async -> Bool) async {
    for _ in 0 ..< 10000 {
      if await condition() { return }
      await Task.yield()
    }
    fatalError("Condition did not become true")
  }

  static func makeManager(_ service: LivePreviewService, adb: ADBService = ADBService()) -> LivePreviewManager {
    LivePreviewManager(livePreviewService: service, adbService: adb, options: options) { _ in }
  }

  static func settle() async {
    for _ in 0 ..< 100 {
      await Task.yield()
    }
  }

  static func click(_ renderer: LivePreviewRenderer) {
    renderer.sendPointer(.down, .touchscreen, .zero, testDisplay.size)
  }

  static func expectNoPointer(_ adb: ADBService) async {
    await settle()
    let preparations = await adb.pointerPreparations
    let events = await adb.pointerEvents
    precondition(preparations.isEmpty, "Unready preview must not prepare a virtual touchscreen")
    precondition(events.isEmpty, "Unready preview must not forward pointer events")
  }

  enum Teardown: CaseIterable {
    case renderer, device, manager, rendererAndManager, deviceAndManager
  }

  static func teardownWaitsForPointerPreparation() async throws {
    for teardown in Teardown.allCases {
      let preparationGate = TestGate()
      let adb = ADBService(pointerPreparationGate: preparationGate)
      let service = LivePreviewService()
      let manager = makeManager(service, adb: adb)
      await manager.start(with: [first])
      let renderer = try await manager.makeRenderer(for: first.id)
      await eventually { await preparationGate.waitCount == 1 }

      var stopped = false
      let stop = Task {
        switch teardown {
        case .renderer:
          await manager.stopRenderer(renderer)
        case .device:
          await manager.updateDevices([])
        case .manager:
          await manager.stop()
        case .rendererAndManager, .deviceAndManager:
          let removing = Task {
            if teardown == .rendererAndManager {
              await manager.stopRenderer(renderer)
            } else {
              await manager.updateDevices([])
            }
          }
          await eventually { await service.stops.count == 1 }
          await manager.stop()
          await removing.value
        }
        stopped = true
      }
      await eventually { await service.active.isEmpty }
      await settle()
      precondition(!stopped, "\(teardown) must wait for queued pointer preparation")

      await preparationGate.open()
      await stop.value
      let preparations = await adb.pointerPreparations
      let activeDevices = await adb.activePointerDeviceIDs
      precondition(preparations == [first.id])
      precondition(activeDevices.isEmpty, "\(teardown) must not leave an input device registered")
      await manager.stop()
    }
  }

  static func removingDevicePreservesOtherPointer() async throws {
    let adb = ADBService()
    let manager = makeManager(LivePreviewService(), adb: adb)
    await manager.start(with: [first, second])
    _ = try await manager.makeRenderer(for: first.id)
    _ = try await manager.makeRenderer(for: second.id)
    await eventually { await adb.activePointerDeviceIDs == [first.id, second.id] }
    await manager.updateDevices([second])
    let activeDevices = await adb.activePointerDeviceIDs
    precondition(activeDevices == [second.id])
    await manager.stop()
  }

  static func pointerWaitsForReadiness() async throws {
    let gate = TestGate()
    let adb = ADBService()
    let manager = makeManager(LivePreviewService(readyGate: gate), adb: adb)
    await manager.start(with: [first])
    let renderer = try await manager.makeRenderer(for: first.id)
    await eventually { await gate.waitCount == 1 }
    click(renderer)
    await expectNoPointer(adb)

    await gate.open()
    await eventually { await adb.pointerPreparations == [first.id] }
    click(renderer)
    await eventually { await adb.pointerEvents.count == 1 }
    await manager.stop()
  }

  static func failedStreamsDoNotPreparePointer() async throws {
    let adb = ADBService()
    // Give each failed stream a fresh readiness gate, like a new retry attempt.
    for _ in 0 ..< 3 {
      let gate = TestGate()
      let manager = makeManager(LivePreviewService(readyGate: gate), adb: adb)
      await manager.start(with: [first])
      let renderer = try await manager.makeRenderer(for: first.id)
      await eventually { await gate.waitCount == 1 }
      await renderer.operation.session.fail()
      click(renderer)
      await expectNoPointer(adb)
      await manager.stopRenderer(renderer)
      await manager.stop()
    }
  }

  static func stoppedPreviewDoesNotPreparePointer() async throws {
    let gate = TestGate()
    let adb = ADBService()
    let manager = makeManager(LivePreviewService(readyGate: gate), adb: adb)
    await manager.start(with: [first])
    let renderer = try await manager.makeRenderer(for: first.id)
    await eventually { await gate.waitCount == 1 }
    await manager.stop()
    click(renderer)
    await expectNoPointer(adb)
  }

  static func removedDeviceDoesNotPreparePointer() async throws {
    let gate = TestGate()
    let adb = ADBService()
    let manager = makeManager(LivePreviewService(readyGate: gate), adb: adb)
    await manager.start(with: [first])
    let renderer = try await manager.makeRenderer(for: first.id)
    await eventually { await gate.waitCount == 1 }
    await manager.updateDevices([])
    click(renderer)
    await expectNoPointer(adb)
    await manager.stop()
  }

  static func stoppedRendererIgnoresLateReadiness() async throws {
    let readyGate = TestGate()
    let stopGate = TestGate()
    let adb = ADBService()
    let service = LivePreviewService(stopGate: stopGate, readyGate: readyGate)
    let manager = makeManager(service, adb: adb)
    await manager.start(with: [first])
    let renderer = try await manager.makeRenderer(for: first.id)
    await eventually { await readyGate.waitCount == 1 }
    let stop = Task { await manager.stopRenderer(renderer) }
    await eventually { await stopGate.waitCount == 1 }
    // The stream can become ready after its renderer has started cleanup.
    await readyGate.open()
    await eventually { renderer.operation.session.isReady }
    click(renderer)
    await expectNoPointer(adb)
    await stopGate.open()
    await stop.value
    await manager.stop()
  }

  static func replacedRendererCannotSendPointer() async throws {
    let adb = ADBService()
    let manager = makeManager(LivePreviewService(), adb: adb)
    await manager.start(with: [first])
    let firstRenderer = try await manager.makeRenderer(for: first.id)
    await eventually { await adb.pointerPreparations.count == 1 }
    await manager.stopRenderer(firstRenderer)
    let replacement = try await manager.makeRenderer(for: first.id)
    await eventually { await adb.pointerPreparations.count == 2 }
    click(firstRenderer)
    await settle()
    let staleEvents = await adb.pointerEvents
    precondition(staleEvents.isEmpty, "A replaced renderer must not send pointer events")
    click(replacement)
    await eventually { await adb.pointerEvents.count == 1 }
    await manager.stop()
  }

  static func stopWaitsForRendererCleanup() async throws {
    let gate = TestGate()
    let service = LivePreviewService(stopGate: gate)
    let manager = makeManager(service)
    await manager.start(with: [first])
    let renderer = try await manager.makeRenderer(for: first.id)
    let stopRenderer = Task { await manager.stopRenderer(renderer) }
    await eventually { await service.stops.count == 1 }
    await manager.stopRenderer(renderer)
    var stopped = false
    let stop = Task { await manager.stop()
      stopped = true
    }
    for _ in 0 ..< 20 {
      await Task.yield()
    }
    precondition(!stopped)
    await gate.open()
    await stopRenderer.value
    await stop.value
    let stops = await service.stops
    let active = await service.active
    precondition(stops.count == 1 && active.isEmpty)
  }

  static func stopDuringRendererStart() async {
    let gate = TestGate()
    let service = LivePreviewService(startGate: gate)
    let manager = makeManager(service)
    await manager.start(with: [first])
    let renderer = Task { try? await manager.makeRenderer(for: first.id) }
    await eventually { await service.starts.count == 1 }
    let stop = Task { await manager.stop() }
    for _ in 0 ..< 20 {
      await Task.yield()
    }
    await gate.open()
    let result = await renderer.value
    await stop.value
    let active = await service.active
    precondition(result == nil && active.isEmpty)
  }

  static func overlappingDeviceUpdates() async {
    let gate = TestGate()
    var displayed: [String] = []
    let manager = LivePreviewManager(
      livePreviewService: LivePreviewService(),
      adbService: ADBService(displayGates: [first.id: gate]), options: options
    ) { displayed = $0.map(\.device.id) }
    let start = Task { await manager.start(with: [first]) }
    for _ in 0 ..< 20 {
      await Task.yield()
    }
    await manager.updateDevices([second])
    await gate.open()
    await start.value
    precondition(displayed == [second.id])
    await manager.stop()
  }

  static func modePropagatesCancellation() async {
    let gate = TestGate()
    let service = LivePreviewService(startGate: gate)
    let mode = LivePreviewMode(
      livePreviewService: service, adbService: ADBService(), options: options,
      mediaDisplayMode: MediaDisplayMode(), preferredDeviceIDProvider: { first.id }, onMediaApplied: {}
    )
    await mode.start(with: [first])
    let renderer = Task { try await mode.makeRenderer(for: first.id) }
    await eventually { await service.starts.count == 1 }
    let stop = Task { await mode.stop() }
    await eventually { mode.isStopping }
    await gate.open()
    do {
      _ = try await renderer.value
      fatalError("Expected cancellation")
    } catch is CancellationError {
      // Expected during an intentional mode switch.
    } catch {
      fatalError("Unexpected error: \(error)")
    }
    await stop.value
    let active = await service.active
    precondition(active.isEmpty)
  }
}
