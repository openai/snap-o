import CoreGraphics
import Foundation
import OSLog

enum StartupCaptureMode { case screenshot, livePreview }
final class EmulatorClipboardSync {}
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
  var mediaDidChange: ((Media) -> Void)?
  enum StreamError: Error { case failed }

  private let readyGate: TestGate?
  private var isStopped = false
  private var hasFormat = false
  private var stopError: Error?

  var isReady: Bool {
    hasFormat && !isStopped
  }

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
  enum StartError: Error { case notReady }

  private var startFailures: Int
  private let startGate: TestGate?
  private let stopGate: TestGate?
  private let readyGate: TestGate?
  private(set) var starts: [String] = []
  private(set) var stops: [UUID] = []
  private(set) var active: Set<UUID> = []

  init(startGate: TestGate? = nil, stopGate: TestGate? = nil, readyGate: TestGate? = nil, startFailures: Int = 0) {
    self.startFailures = startFailures
    self.startGate = startGate
    self.stopGate = stopGate
    self.readyGate = readyGate
  }

  func start(for deviceID: String, options _: LivePreviewOptions) async throws -> LivePreviewOperationHandle {
    starts.append(deviceID)
    await startGate?.wait()
    if startFailures > 0 {
      startFailures -= 1
      throw StartError.notReady
    }
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
  enum DisplayError: Error { case notReady }

  private var displayGates: [String: TestGate]
  private var displayFailures: [String: Int]
  private var densityFailures: [String: Int]
  private var bootingDeviceIDs: Set<String> = []
  private(set) var displayRequests: [String] = []
  private(set) var retryDelays: [Duration] = []
  private let pointerPreparationGate: TestGate?
  private(set) var pointerPreparations: [String] = []
  private(set) var pointerEvents: [LivePreviewPointerEvent] = []
  private(set) var activePointerDeviceIDs: Set<String> = []

  init(
    displayGates: [String: TestGate] = [:],
    pointerPreparationGate: TestGate? = nil,
    displayFailures: [String: Int] = [:],
    densityFailures: [String: Int] = [:]
  ) {
    self.displayGates = displayGates
    self.displayFailures = displayFailures
    self.densityFailures = densityFailures
    self.pointerPreparationGate = pointerPreparationGate
  }

  func exec() -> ADBService {
    self
  }

  func screencapPNG(deviceID: String) throws -> Data {
    Data()
  }

  func keyEvent(deviceID: String, keyCode: String) throws -> String {
    ""
  }

  func isBootComplete(deviceID: String) throws -> Bool {
    !bootingDeviceIDs.contains(deviceID)
  }

  func recordRetryDelay(_ delay: Duration) {
    retryDelays.append(delay)
  }

  func setBooting(_ booting: Bool, deviceID: String) {
    if booting { bootingDeviceIDs.insert(deviceID) } else { bootingDeviceIDs.remove(deviceID) }
  }

  func displayDensity(deviceID: String) throws -> Int {
    if densityFailures[deviceID, default: 0] > 0 {
      densityFailures[deviceID, default: 0] -= 1
      throw DisplayError.notReady
    }
    return 3
  }

  func displaySize(deviceID: String) async throws -> String {
    displayRequests.append(deviceID)
    await displayGates[deviceID]?.wait()
    if displayFailures[deviceID, default: 0] > 0 {
      displayFailures[deviceID, default: 0] -= 1
      throw DisplayError.notReady
    }
    return "1080x2400"
  }

  func setDisplayGate(_ gate: TestGate, for deviceID: String) {
    displayGates[deviceID] = gate
  }

  func recordPointerPreparation(deviceID: String) async {
    // Model an actor call queued before registration, even if its task is cancelled.
    await pointerPreparationGate?.wait()
    pointerPreparations.append(deviceID)
    activePointerDeviceIDs.insert(deviceID)
  }

  func recordPointerStop(deviceID: String) {
    activePointerDeviceIDs.remove(deviceID)
  }

  func recordPointerStopAll() {
    activePointerDeviceIDs.removeAll()
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
  var locations: [CGPoint]
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

  func stopDevice(_ deviceID: String) async {
    await adb.recordPointerStop(deviceID: deviceID)
  }

  func stopAll() async {
    await adb.recordPointerStopAll()
  }

  func enqueue(_ event: LivePreviewPointerEvent) async {
    await adb.recordPointerEvent(event)
  }
}

@MainActor
final class LivePreviewRenderer {
  let operation: LivePreviewOperationHandle
  let sendPointer: (LivePreviewPointerAction, LivePreviewPointerSource, [CGPoint], CGSize) -> Void
  var deviceID: String {
    operation.deviceID
  }

  init(
    operation: LivePreviewOperationHandle,
    pointerHandler: @escaping (LivePreviewPointerAction, LivePreviewPointerSource, [CGPoint], CGSize) -> Void
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
  func livePreviewConnection(for deviceID: String) -> LivePreviewConnection?
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
