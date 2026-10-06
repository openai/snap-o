import Foundation
import Observation

@MainActor
final class ShutdownProbe {
  enum Owner: CaseIterable {
    case startup, workspaces, manager, preview, reservations, tracker, files, history
  }

  let target = DeviceTarget(serial: "shutdown-test", transportID: "1")
  var gates: [Owner: TestGate] = [:]
  var leases: [Owner: ShowTouchesOverride] = [:]
  var started: Set<Owner> = []
  var finished: Set<Owner> = []
  var invalidTargets: Set<Owner> = []
  var admissionClosed = false
  var exportsClosed = false
  var showsTouches = false
  var restorationGate: TestGate?
  let startupRequests = TestValue<[StartupRequest]>([])

  struct StartupRequest {
    let mode: StartupCaptureMode
    let devices: [Device]
  }

  func finish(_ owner: Owner) async {
    started.insert(owner)
    testChanges.signal()
    await gates[owner]?.wait()
    if let lease = leases[owner] {
      if !target.isValid { invalidTargets.insert(owner) }
      await lease.restore(using: ADBService())
    }
    if owner == .tracker { target.invalidate() }
    finished.insert(owner)
    testChanges.signal()
  }
}

@MainActor
enum RuntimeTestEnvironment {
  static var probe = ShutdownProbe()
}

@MainActor
final class ADBService {
  private let probe = RuntimeTestEnvironment.probe
  func exec() -> ADBService {
    self
  }

  func bound(to _: DeviceTarget) -> ADBService {
    self
  }

  func withTimeout(_: Duration) -> ADBService {
    self
  }

  func getShowTouches(deviceID: String) throws -> Bool {
    probe.showsTouches
  }

  func setShowTouches(deviceID: String, enabled: Bool) async throws {
    if !enabled { await probe.restorationGate?.wait() }
    precondition(probe.target.isValid, "Restoration must finish before target invalidation")
    probe.showsTouches = enabled
  }

  func startScreenrecord(deviceID: String, bugReport: Bool) throws -> RecordingSession {
    RecordingSession()
  }
}

struct RecordingSession {}
protocol ScreenRecording: Sendable {}
struct ADBScreenRecording: ScreenRecording {
  init(session: RecordingSession, adb: ADBService) {}
}

struct NativeScreenRecording: ScreenRecording {
  static func start(target: DeviceTarget) async throws -> NativeScreenRecording {
    Self()
  }
}

enum EmulatorGRPCEndpoint {
  static func isEmulator(_ serial: String) -> Bool {
    false
  }
}

@MainActor
final class AndroidHostClient {
  func ensureADBServerRunning() async throws {}
}

@MainActor
final class DeviceTracker {
  private let probe = RuntimeTestEnvironment.probe
  init(adbService: ADBService, recoverADBServer: @escaping @Sendable () async throws -> Void) {}
  func stopTracking() async {
    await probe.finish(.tracker)
  }
}

@Observable
@MainActor
final class DeviceManager {
  var inventory = DeviceInventory()
  private var shutdownTask: Task<Void, Never>?
  var isShuttingDown: Bool {
    shutdownTask != nil
  }

  private let probe = RuntimeTestEnvironment.probe
  init(adb: ADBService, deviceTracker: DeviceTracker, client: AndroidHostClient) {}
  func start() {}
  func shutdown() -> Task<Void, Never> {
    if let shutdownTask { return shutdownTask }
    let task = Task { await probe.finish(.manager) }
    shutdownTask = task
    return task
  }
}

@MainActor
final class CaptureCoordinator {
  private let probe = RuntimeTestEnvironment.probe
  func beginShutdown() {
    probe.admissionClosed = true
  }

  func waitUntilIdle() async {
    await probe.finish(.reservations)
  }
}

struct CaptureMedia {}

@MainActor
final class FileStore {
  private let probe = RuntimeTestEnvironment.probe
  init(frameExportHandler: @escaping @MainActor @Sendable (CaptureMedia) -> Void) {}
  func beginShutdown() {
    probe.exportsClosed = true
  }

  func shutdown() async {
    await probe.finish(.files)
  }
}

@MainActor
final class CaptureHistory {
  let repository: Void = ()
  private let probe = RuntimeTestEnvironment.probe
  func start() {}
  func recordFrame(_ media: CaptureMedia) {}
  func shutdown() async {
    await probe.finish(.history)
  }
}

@MainActor
final class RecordingCapture {
  typealias StartRecording = @Sendable (Device, Bool) async throws -> any ScreenRecording
  init(
    devices: [Device], options: RecordingOptions, adb: ADBService, fileStore: FileStore,
    coordinator: CaptureCoordinator, history: Void, startRecording: @escaping StartRecording,
    loadRecording: (@Sendable (URL, Device, Date) async throws -> CaptureMedia)?, timestampSource: CaptureTimestampSource
  ) {}
}

struct ScreenshotService {
  init(adb: ADBService, fileStore: FileStore) {}
}

@MainActor
final class ScreenshotCapture {
  init(
    devices: [Device], screenshots: ScreenshotService, fileStore: FileStore,
    history: Void, coordinator: CaptureCoordinator
  ) {}
}

struct CaptureTimestampSource {}

@MainActor
final class LivePreviewService {
  private let probe = RuntimeTestEnvironment.probe
  init(coordinator: CaptureCoordinator, adb: ADBService, settings: AppSettings) {}
  func shutdown() async {
    await probe.finish(.preview)
  }
}

enum StartupCaptureMode { case livePreview, screenshot }

@MainActor
@Observable
final class AppSettings {
  static let shared = AppSettings()
  var startupCaptureMode = StartupCaptureMode.livePreview
  var lastViewedDeviceID: String?
  var showTouchesDuringCapture = false
}

@MainActor
final class StartupCapturePreparation {
  private let probe = RuntimeTestEnvironment.probe
  var isAvailable = true
  init(
    screenshots: @escaping @MainActor ([Device]) -> ScreenshotCapture,
    livePreview: LivePreviewService,
    makeEmulatorControls: @escaping @MainActor (DeviceTarget) -> EmulatorControlsController?
  ) {}
  func prepare(mode: StartupCaptureMode, devices: [Device]) {
    probe.startupRequests.value.append(.init(mode: mode, devices: devices))
  }

  func discard() async {
    await probe.finish(.startup)
  }
}

@MainActor
final class EmulatorControlsController {
  static func live(target: DeviceTarget) -> EmulatorControlsController? {
    nil
  }
}

@MainActor
final class CaptureWorkspaces {
  private let probe = RuntimeTestEnvironment.probe
  init(
    captureServices: CaptureServices, deviceManager: DeviceManager, fileStore: FileStore,
    adbService: ADBService, history: CaptureHistory
  ) {}
  func beginShutdown() -> Task<Void, Never> {
    Task { await probe.finish(.workspaces) }
  }
}
