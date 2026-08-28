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
  private(set) var waitCount = 0

  func wait() async {
    waitCount += 1
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
  enum StreamError: Error { case failed }

  private let readyGate: TestGate?
  private var isStopped = false
  private var hasFormat = false
  private var stopError: Error?

  var isReady: Bool { hasFormat && !isStopped }

  init(readyGate: TestGate?) {
    self.readyGate = readyGate
  }

  func waitUntilReady() async throws -> Media {
    await readyGate?.wait()
    if let stopError { throw stopError }
    guard !isStopped else { throw CancellationError() }
    hasFormat = true
    return .livePreview(capturedAt: Date(), display: testDisplay)
  }

  func cancel() async {
    isStopped = true
    await readyGate?.open()
  }

  func fail() async {
    stopError = StreamError.failed
    await cancel()
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
  private(set) var pointerPreparations: [String] = []
  private(set) var pointerEvents: [LivePreviewPointerEvent] = []
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

  func recordPointerPreparation(deviceID: String) {
    pointerPreparations.append(deviceID)
  }

  func recordPointerEvent(_ event: LivePreviewPointerEvent) {
    pointerEvents.append(event)
  }
}

enum LivePreviewPointerAction { case down }
enum LivePreviewPointerSource { case mouse, touchscreen }
struct LivePreviewPointerEvent {
  let deviceID: String
  let action: LivePreviewPointerAction
  let source: LivePreviewPointerSource
  let location: CGPoint
  let displaySize: CGSize
}

actor LivePreviewPointerInjector {
  private let adb: ADBService

  init(adb: ADBService) {
    self.adb = adb
  }

  func prepare(deviceID: String) async {
    await adb.recordPointerPreparation(deviceID: deviceID)
  }

  func stopDevice(_: String) {}
  func stopAll() {}
  func enqueue(_ event: LivePreviewPointerEvent) async {
    await adb.recordPointerEvent(event)
  }
}

@MainActor
final class LivePreviewRenderer {
  let operation: LivePreviewOperationHandle
  let sendPointer: (LivePreviewPointerAction, LivePreviewPointerSource, CGPoint, CGSize) -> Void
  var deviceID: String {
    operation.deviceID
  }

  init(
    operation: LivePreviewOperationHandle,
    pointerHandler: @escaping (LivePreviewPointerAction, LivePreviewPointerSource, CGPoint, CGSize) -> Void
  ) {
    self.operation = operation
    sendPointer = pointerHandler
  }
}

@MainActor
final class AppSettings {
  static let shared = AppSettings()
  var startupCaptureMode = StartupCaptureMode.livePreview
  var recordAsBugReport = false
  var showTouchesDuringCapture = false
}

struct FileStore {}

@MainActor
protocol LivePreviewHosting: AnyObject {
  func startLivePreviewStream(for deviceID: String) async -> LivePreviewRenderer?
  func stopLivePreviewStream(_ renderer: LivePreviewRenderer) async
}

actor DeviceTracker {
  private(set) var latestDevices: [Device]
  private var continuation: AsyncStream<[Device]>.Continuation?

  init(devices: [Device]) {
    latestDevices = devices
  }

  func deviceStream() -> AsyncStream<[Device]> {
    let (stream, continuation) = AsyncStream<[Device]>.makeStream()
    self.continuation = continuation
    continuation.yield(latestDevices)
    return stream
  }

  func updateDevices(_ devices: [Device]) {
    latestDevices = devices
    continuation?.yield(devices)
  }
}

struct RecordingOptions {
  let recordsBugReport: Bool
  let showsTouches: Bool
}

struct RecordingOperationHandle {
  let completion = TestGate()
}

struct RecordingOperationResult {
  let media: [CaptureMedia]
  let error: Error?
}

actor RecordingService {
  private(set) var requests: [[String]] = []

  func start(for devices: [Device], options _: RecordingOptions) throws -> RecordingOperationHandle {
    requests.append(devices.map(\.id))
    return RecordingOperationHandle()
  }

  func waitForCompletion(of handle: RecordingOperationHandle) async -> RecordingOperationResult? {
    await handle.completion.wait()
    return nil
  }

  func updateConnectedDeviceIDs(_: Set<String>, for _: RecordingOperationHandle) {}

  func finish(_ handle: RecordingOperationHandle) async {
    await handle.completion.open()
  }

  func cancel(_ handle: RecordingOperationHandle) async {
    await handle.completion.open()
  }
}
