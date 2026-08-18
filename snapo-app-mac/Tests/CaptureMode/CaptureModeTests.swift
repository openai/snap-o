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
    try await stopWaitsForRendererCleanup()
    await stopDuringRendererStart()
    await overlappingDeviceUpdates()
    await modePropagatesCancellation()
    print("Capture mode tests passed (4 cases)")
  }

  static func eventually(_ condition: () async -> Bool) async {
    for _ in 0 ..< 10000 {
      if await condition() { return }
      await Task.yield()
    }
    fatalError("Condition did not become true")
  }

  static func makeManager(_ service: LivePreviewService) -> LivePreviewManager {
    LivePreviewManager(livePreviewService: service, adbService: ADBService(), options: options) { _ in }
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
