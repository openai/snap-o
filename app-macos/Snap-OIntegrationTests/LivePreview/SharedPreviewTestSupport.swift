import AppKit
@preconcurrency import AVFoundation
import Clocks
import Dependencies
import DependenciesTestSupport
import Observation
#if !SNAPO_STANDALONE_TESTS
@testable import Snap_O
#endif
import Testing

enum SharedPreviewTestSupport {
  @Observable
  @MainActor
  final class Fixture {
    let adb: ADBService
    let coordinator = CaptureCoordinator()
    let defaults: UserDefaults
    let suite = "SharedPreviewTests." + UUID().uuidString
    let settings: AppSettings
    let pasteboard = TextPasteboardDouble()
    var owners: [DevicePreview] = []
    var sources: [Source] = []
    var keyboards: [Keyboard] = []
    var pointers: [Pointer] = []
    var clipboards: [Clipboard] = []
    var clipboardCleanup: TestSuspension?
    var keyboardConnections = 0
    var clipboardConnections = 0
    var sourceCleanup: TestSuspension?
    var preparationGate: TestSuspension?
    var videoStartupError: Error?
    var makeFileDrop: (Device) -> DeviceFileDrop = { DeviceFileDrop(device: $0) }
    @ObservationIgnored lazy var service = LivePreviewService(
      coordinator: coordinator, adb: adb,
      makeFileDrop: { [unowned self] in makeFileDrop($0) },
      makePreview: { [unowned self] in makeOwner($0) }
    )

    init(adb: ADBService = ADBService()) throws {
      self.adb = adb
      defaults = try #require(UserDefaults(suiteName: suite))
      settings = AppSettings(defaults: defaults)
      settings.syncClipboard = true
    }

    func target(_ serial: String = "emulator-5554") -> DeviceTarget {
      DeviceTarget(serial: serial, transportID: "1")
    }

    func device(_ target: DeviceTarget) -> Device {
      Device(
        id: target.serial, model: "Test", androidVersion: "16", vendorModel: nil,
        manufacturer: nil, avdName: nil, connection: target
      )
    }

    func makeOwner(_ target: DeviceTarget) -> DevicePreview {
      let gate = preparationGate
      let cleanup = sourceCleanup
      let clipboardCleanup = clipboardCleanup
      let preparation = Task {
        try? await gate?.wait()
        let touches = await ShowTouchesOverride.apply(target: nil, enabled: false, using: adb)
        return DevicePreview.Preparation(touches: touches, density: 1)
      }
      let transport = Keyboard()
      keyboards.append(transport)
      let keyboard = LivePreviewKeyboard(deviceID: target.serial, target: target, pasteboard: pasteboard) { _ in
        await MainActor.run { self.keyboardConnections += 1 }
        return transport
      }
      let backend = Pointer()
      pointers.append(backend)
      let pointer = LivePreviewPointerInjector(makePreferredBackend: { _ in backend }, makeFallbackBackend: { _ in backend })
      let owner = DevicePreview(
        target: target, adb: adb, boot: Task {}, preparation: preparation, keyboard: keyboard, pointer: pointer,
        makeSource: {
          let source = Source(cleanup: cleanup)
          self.sources.append(source)
          return source
        }, makeClipboard: { allowed in
          ClipboardSync(settings: self.settings, pasteboard: self.pasteboard, maySynchronize: allowed) { _, body in
            self.clipboardConnections += 1
            let transport = Clipboard()
            self.clipboards.append(transport)
            let result: Result<Void, Error>
            do {
              try await body(transport)
              result = .success(())
            } catch {
              result = .failure(error)
            }
            // Model transport cleanup that must finish even after cancellation.
            let cleanup = Task { try? await clipboardCleanup?.wait() }
            await cleanup.value
            try result.get()
          }
        }
      )
      if let videoStartupError {
        owner.video = PreviewVideo(makeSession: { throw videoStartupError }, canReconnect: { target.isValid })
      }
      owners.append(owner)
      return owner
    }

    func ready(_ attachment: LivePreviewAttachment) async throws {
      try await waitForState { attachment.preview?.inputReady == true && attachment.preview?.videoState == .streaming }
    }

    func focus(_ attachment: LivePreviewAttachment) async throws {
      attachment.setVisible(true)
      attachment.setFocused(true)
      try await waitForState { attachment.acceptsInput }
      try await ready(attachment)
    }

    func close() async {
      await service.shutdown()
      owners.removeAll()
      defaults.removePersistentDomain(forName: suite)
    }
  }

  @Observable
  @MainActor
  final class Source: LivePreviewFrameSource {
    let hasIndependentFrames = true
    let cleanup: TestSuspension?
    var stops = 0
    private var deliver: (@MainActor @Sendable (LivePreviewFrameEvent) -> Void)?
    private var cleanupWork: Task<Void, Never>?
    init(cleanup: TestSuspension?) {
      self.cleanup = cleanup
    }

    func start(deliver: @escaping @MainActor @Sendable (LivePreviewFrameEvent) -> Void) {
      self.deliver = deliver
      var format: CMVideoFormatDescription?
      CMVideoFormatDescriptionCreate(
        allocator: kCFAllocatorDefault, codecType: kCMVideoCodecType_H264,
        width: 100, height: 200, extensions: nil, formatDescriptionOut: &format
      )
      if let format { deliver(.format(format)) }
    }

    func fail() {
      deliver?(.stopped(CocoaError(.fileReadUnknown)))
    }

    func stop() {
      stops += 1
      deliver = nil
      if let cleanup { cleanupWork = Task { try? await cleanup.wait() } }
    }

    func waitUntilStopped() async {
      await cleanupWork?.value
    }
  }

  actor Pointer: LivePreviewPointerBackend {
    private(set) var events: [LivePreviewPointerEvent] = []
    private let changes = TestSignal()
    func send(_ event: LivePreviewPointerEvent) async throws {
      events.append(event)
      changes.signal()
    }

    func waitForEvents(_ count: Int) async throws {
      while events.count < count {
        let revision = changes.revision
        try await changes.wait(after: revision)
      }
    }
  }

  actor Clipboard: ClipboardTransport {
    private var receiver: (@Sendable (String) async -> Void)?
    private let changes = TestSignal()
    func getText() async throws -> String {
      ""
    }

    func setText(_ text: String) async throws {}
    func receive(_ onText: @escaping @Sendable (String) async -> Void) async throws {
      receiver = onText
      changes.signal()
      try await suspendUntilCancelled()
    }

    func deliver(_ text: String) async {
      await receiver?(text)
    }

    func waitUntilReceiving() async throws {
      while receiver == nil {
        let revision = changes.revision
        try await changes.wait(after: revision)
      }
    }
  }

  final class Keyboard: LivePreviewKeyboardTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let changes = TestSignal()
    private var received: [LivePreviewKeyboardEvent] = []
    private var closed = false
    private var copyGate: TestSuspension?
    var events: [LivePreviewKeyboardEvent] {
      lock.withLock { received }
    }

    var isClosed: Bool {
      lock.withLock { closed }
    }

    func holdCopy(_ gate: TestSuspension) {
      lock.withLock { copyGate = gate }
    }

    func send(_ event: LivePreviewKeyboardEvent) async throws -> LivePreviewKeyboardResponse {
      let gate = lock.withLock { received.append(event)
        return copyGate
      }
      changes.signal()
      if event == .copy {
        try? await gate?.wait()
        return .copied("stale selection")
      }
      return .sent
    }

    func close() {
      lock.withLock { closed = true }
    }

    func waitForEvents(_ count: Int) async throws {
      while true {
        let revision = changes.revision
        if events.count >= count { return }
        try await changes.wait(after: revision)
      }
    }
  }
}
