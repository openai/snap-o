import CoreGraphics
import Dependencies
import Foundation
import Observation

@MainActor
protocol PreviewStatus: AnyObject {
  var videoState: PreviewVideo.Phase { get }
  var display: DisplayInfo? { get }
  var inputReady: Bool { get }
  var keyboardError: String? { get }
  var clipboardUnavailable: Bool { get }
}

/// Owns device preparation and input. Video can recover without replacing these resources.
@Observable
@MainActor
final class DevicePreview: PreviewStatus {
  struct Preparation {
    let touches: ShowTouchesOverride?
    let density: CGFloat?
  }

  let target: DeviceTarget
  let keyboard: LivePreviewKeyboard
  let pointer: LivePreviewPointerInjector
  let rotation: LivePreviewRotation
  private(set) var inputReady = false
  private(set) var preparationFinished = false
  private var density: CGFloat?
  private var clipboard: ClipboardSync?
  private var allowsClipboard = false
  private let adb: ADBService
  private let settings: AppSettings?
  private let boot: Task<Void, Error>
  private let preparation: Task<Preparation, Never>
  private let makeSource: @MainActor () -> any LivePreviewFrameSource
  private let makeClipboard: @MainActor (@escaping @MainActor () -> Bool) -> ClipboardSync
  @ObservationIgnored private var preparationObserver: Task<Void, Never>?
  @ObservationIgnored private var clipboardWork: Task<Void, Never>?
  @ObservationIgnored private var closing: Task<Void, Never>?
  private var isClosed = false

  @ObservationIgnored lazy var video = PreviewVideo(
    makeSession: { [weak self] in
      guard let self, !isClosed else { throw CancellationError() }
      if !target.isLocalEmulator { try await boot.value }
      try Task.checkCancellation()
      guard !isClosed, target.isValid else { throw CancellationError() }
      return LivePreviewSession(deviceID: target.serial, densityScale: density, source: makeSource())
    },
    canReconnect: { [weak self] in self?.target.isValid == true && self?.isClosed == false }
  )

  var videoState: PreviewVideo.Phase {
    video.phase
  }

  var display: DisplayInfo? {
    video.display
  }

  var keyboardError: String? {
    keyboard.errorMessage
  }

  var clipboardUnavailable: Bool {
    clipboard?.isUnavailable == true
  }

  init(
    target: DeviceTarget, adb: ADBService, settings: AppSettings? = nil,
    boot: Task<Void, Error>, preparation: Task<Preparation, Never>,
    keyboard: LivePreviewKeyboard, pointer: LivePreviewPointerInjector,
    makeSource: @escaping @MainActor () -> any LivePreviewFrameSource,
    makeClipboard: @escaping @MainActor (@escaping @MainActor () -> Bool) -> ClipboardSync
  ) {
    self.target = target
    self.adb = adb
    self.settings = settings
    self.boot = boot
    self.preparation = preparation
    self.keyboard = keyboard
    self.pointer = pointer
    rotation = LivePreviewRotation(target: target)
    self.makeSource = makeSource
    self.makeClipboard = makeClipboard
  }

  convenience init(target: DeviceTarget, adb: ADBService, settings: AppSettings) {
    @Dependency(\.continuousClock)
    var clock
    let boot = Task {
      let exec = await adb.exec().bound(to: target)
      var delay = Duration.seconds(1)
      while true {
        try Task.checkCancellation()
        _ = try target.requireTransport(for: target.serial)
        if await (try? exec.isBootComplete(deviceID: target.serial)) == true { break }
        try await clock.sleep(for: delay)
        delay = min(delay * 2, .seconds(10))
      }
      try Task.checkCancellation()
      _ = try? await exec.withTimeout(.seconds(1)).keyEvent(deviceID: target.serial, keyCode: "KEYCODE_WAKEUP")
    }
    let preparation = Task<Preparation, Never> {
      do { try await boot.value } catch { return Preparation(touches: nil, density: nil) }
      guard !Task.isCancelled, target.isValid else { return Preparation(touches: nil, density: nil) }
      async let touches = ShowTouchesOverride.apply(target: target, enabled: settings.showTouchesDuringCapture, using: adb)
      var density: CGFloat?
      if target.isLocalEmulator {
        let exec = await adb.exec().bound(to: target)
        while !Task.isCancelled, target.isValid {
          if let value = try? await exec.displayDensity(deviceID: target.serial) {
            density = CGFloat(value)
            break
          }
          do { try await clock.sleep(for: .seconds(1)) } catch { break }
        }
      }
      return await Preparation(touches: touches, density: density)
    }
    let keyboard = LivePreviewKeyboard(deviceID: target.serial, target: target) { _ in
      try await DeviceKeyboardTransport.connect(serial: target.serial, adb: ADBClient().bound(to: target))
    }
    self.init(
      target: target, adb: adb, settings: settings, boot: boot, preparation: preparation,
      keyboard: keyboard, pointer: LivePreviewPointerInjector(adb: adb),
      makeSource: { DeviceVideoSource(target: target) },
      makeClipboard: { allowed in ClipboardSync(settings: settings, maySynchronize: allowed) }
    )
  }

  func start() {
    guard !isClosed, preparationObserver == nil else { return }
    video.start()
    preparationObserver = Task {
      let prepared = await preparation.value
      guard !isClosed, !Task.isCancelled, target.isValid else { return }
      preparationFinished = true
      density = prepared.density
      if let density { video.session?.updateDensityScale(density) }
      inputReady = prepared.touches != nil
      if inputReady { await pointer.prepare(target: target) }
      guard let settings, let touches = prepared.touches else { return }
      for await enabled in Observations({ settings.showTouchesDuringCapture }) {
        guard !Task.isCancelled, !isClosed, target.isValid else { return }
        await touches.setEnabled(enabled, using: adb)
      }
    }
  }

  func setClipboardEnabled(_ enabled: Bool) {
    allowsClipboard = enabled && !isClosed
    guard allowsClipboard, clipboard == nil else { return }
    let sync = makeClipboard { [weak self] in self?.allowsClipboard == true && self?.isClosed == false }
    clipboard = sync
    clipboardWork = Task {
      await sync.run(target: target)
      if clipboard === sync {
        clipboard = nil
        clipboardWork = nil
      }
    }
  }

  func stopClipboard() async {
    allowsClipboard = false
    clipboard?.stop()
    await clipboardWork?.value
  }

  func close() async {
    if let closing { await closing.value
      return
    }
    isClosed = true
    inputReady = false
    allowsClipboard = false
    boot.cancel()
    preparation.cancel()
    preparationObserver?.cancel()
    clipboard?.stop()
    let keyboardCleanup = keyboard.beginShutdown()
    let closing = Task {
      async let videoCleanup: Void = video.close()
      async let pointerCleanup: Void = pointer.stopAll()
      async let rotationCleanup: Void = rotation.stop()
      let prepared = await preparation.value
      await preparationObserver?.value
      await clipboardWork?.value
      await keyboardCleanup.value
      await videoCleanup
      await pointerCleanup
      await rotationCleanup
      await prepared.touches?.restore(using: adb)
      _ = await boot.result
    }
    self.closing = closing
    await closing.value
  }
}
