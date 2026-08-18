import CoreGraphics
import Foundation
import OSLog
import SnapODeviceClient

enum StartupCaptureMode { case screenshot, livePreview }
enum SnapOLog {
  static let ui = Logger(subsystem: "Snap-O.StartupTests", category: "test")
}

actor TestGate {
  private var isOpen = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func wait() async {
    guard !isOpen else { return }
    await withCheckedContinuation { waiters.append($0) }
  }

  func open() {
    isOpen = true
    let pending = waiters
    waiters.removeAll()
    for waiter in pending {
      waiter.resume()
    }
  }
}

let testDisplay = DisplayInfo(size: CGSize(width: 1080, height: 2400), densityScale: 3)

func testDevice(_ id: String) -> Device {
  Device(id: id, model: id, androidVersion: "16", vendorModel: nil, manufacturer: nil, avdName: nil)
}

func testCapture(_ device: Device, age: TimeInterval = 0) -> CaptureMedia {
  CaptureMedia(device: device, media: .image(
    url: URL(fileURLWithPath: "/tmp/\(device.id).png"),
    capturedAt: Date().addingTimeInterval(-age),
    display: testDisplay
  ))
}

struct LivePreviewOptions: Equatable { let showsTouches: Bool }
struct LivePreviewOperationHandle {
  let id: UUID
  let deviceID: String
  let session: LivePreviewSession
}

@MainActor
final class LivePreviewSession {
  private let readyGate: TestGate?
  private var isStopped = false

  init(readyGate: TestGate?) {
    self.readyGate = readyGate
  }

  func waitUntilReady() async throws -> Media {
    await readyGate?.wait()
    guard !isStopped else { throw CancellationError() }
    return .livePreview(capturedAt: Date(), display: testDisplay)
  }

  func cancel() async {
    isStopped = true
    await readyGate?.open()
  }
}

actor LivePreviewService {
  private let startGate: TestGate?
  private let stopGate: TestGate?
  private let readyGate: TestGate?
  private(set) var starts: [String] = []
  private(set) var stops: [UUID] = []
  private(set) var active: Set<UUID> = []

  init(startGate: TestGate? = nil, stopGate: TestGate? = nil, readyGate: TestGate? = nil) {
    self.startGate = startGate
    self.stopGate = stopGate
    self.readyGate = readyGate
  }

  func start(for deviceID: String, options _: LivePreviewOptions) async throws -> LivePreviewOperationHandle {
    starts.append(deviceID)
    await startGate?.wait()
    let handle = await LivePreviewOperationHandle(
      id: UUID(), deviceID: deviceID, session: LivePreviewSession(readyGate: readyGate)
    )
    active.insert(handle.id)
    return handle
  }

  func stop(_ handle: LivePreviewOperationHandle) async -> Error? {
    stops.append(handle.id)
    await stopGate?.wait()
    await handle.session.cancel()
    active.remove(handle.id)
    return nil
  }
}

actor ScreenshotService {
  private let gate: TestGate?
  private(set) var requests: [[String]] = []

  init(gate: TestGate? = nil) {
    self.gate = gate
  }

  func capture(for devices: [Device]) async -> ScreenshotCaptureResult {
    requests.append(devices.map(\.id))
    await gate?.wait()
    return ScreenshotCaptureResult(media: devices.map { testCapture($0) }, failures: [])
  }
}

actor ADBService {
  private let displayGates: [String: TestGate]
  init(displayGates: [String: TestGate] = [:]) {
    self.displayGates = displayGates
  }

  func exec() -> ADBService {
    self
  }

  func displayDensity(deviceID _: String) throws -> Int {
    3
  }

  func displaySize(deviceID: String) async throws -> String {
    await displayGates[deviceID]?.wait()
    return "1080x2400"
  }
}

enum LivePreviewPointerAction { case down }
enum LivePreviewPointerSource { case mouse }
struct LivePreviewPointerEvent {
  let deviceID: String
  let action: LivePreviewPointerAction
  let source: LivePreviewPointerSource
  let location: CGPoint
  let displaySize: CGSize
}

actor LivePreviewPointerInjector {
  init(adb _: ADBService) {}
  func prepare(deviceID _: String) {}
  func stopDevice(_: String) {}
  func stopAll() {}
  func enqueue(_: LivePreviewPointerEvent) {}
}

@MainActor
final class LivePreviewRenderer {
  let operation: LivePreviewOperationHandle
  var deviceID: String {
    operation.deviceID
  }

  init(
    operation: LivePreviewOperationHandle,
    pointerHandler _: @escaping (LivePreviewPointerAction, LivePreviewPointerSource, CGPoint, CGSize) -> Void
  ) {
    self.operation = operation
  }
}
