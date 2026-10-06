import Clocks
import Dependencies
import Foundation

/// Starts the preferred capture before a window is ready to claim it.
@MainActor
final class StartupCapturePreparation {
  private enum Preparation {
    case screenshots(devices: [Device], batch: ScreenshotCapture, startedAt: AnyClock<Duration>.Instant)
    case livePreview(device: Device, attachment: LivePreviewAttachment)
  }

  private let clock: AnyClock<Duration>
  private let screenshots: @MainActor ([Device]) -> ScreenshotCapture
  private let livePreview: LivePreviewService
  private let makeEmulatorControls: @MainActor (DeviceTarget) -> EmulatorControlsController?
  private var preparation: Preparation?
  private var cleanupTask: Task<Void, Never>?
  private var expirationTask: Task<Void, Never>?
  private(set) var isAvailable = true

  init(
    screenshots: @escaping @MainActor ([Device]) -> ScreenshotCapture, livePreview: LivePreviewService,
    makeEmulatorControls: @escaping @MainActor (DeviceTarget) -> EmulatorControlsController? = { _ in nil }
  ) {
    @Dependency(\.continuousClock)
    var clock
    self.clock = AnyClock(clock)
    self.screenshots = screenshots
    self.livePreview = livePreview
    self.makeEmulatorControls = makeEmulatorControls
  }

  func prepare(mode: StartupCaptureMode, devices: [Device]) {
    guard isAvailable else { return }
    switch (mode, preparation) {
    case (.screenshot, .screenshots(let prepared, _, _))
      where prepared.map(\.id) == devices.map(\.id) && prepared.map(\.connection) == devices.map(\.connection):
      return
    case (.livePreview, .livePreview(let device, _))
      where device.id == devices.first?.id && device.connection == devices.first?.connection:
      return
    default:
      break
    }

    discardCurrentPreparation()
    guard let firstDevice = devices.first else { return }
    switch mode {
    case .screenshot:
      Perf.step(.appFirstSnapshot, "preload screenshot")
      let batch = screenshots(devices)
      batch.start()
      preparation = .screenshots(devices: devices, batch: batch, startedAt: clock.now)
    case .livePreview:
      Perf.step(.appFirstSnapshot, "preload live preview")
      if let attachment = livePreview.attach(to: firstDevice, makeEmulatorControls: makeEmulatorControls) {
        preparation = .livePreview(device: firstDevice, attachment: attachment)
        expirationTask = Task { [clock] in
          do { try await clock.sleep(for: .seconds(5)) } catch { return }
          guard !Task.isCancelled else { return }
          expirationTask = nil
          await discard()
        }
      }
    }
  }

  func claimScreenshots(for devices: [Device]) -> ScreenshotCapture? {
    guard isAvailable else { return nil }
    if case .screenshots(_, let batch, let startedAt) = preparation,
       batch.isComplete, startedAt.duration(to: clock.now) > .seconds(1) {
      discardCurrentPreparation()
    }
    prepare(mode: .screenshot, devices: devices)
    isAvailable = false
    guard case .screenshots(_, let batch, _) = preparation else { return nil }
    preparation = nil
    Perf.step(.appFirstSnapshot, "claim preloaded screenshot")
    return batch
  }

  func claimLivePreview(for device: Device) -> LivePreviewAttachment? {
    guard isAvailable else { return nil }
    prepare(mode: .livePreview, devices: [device])
    isAvailable = false
    guard case .livePreview(_, let attachment) = preparation else { return nil }
    preparation = nil
    expirationTask?.cancel()
    expirationTask = nil
    Perf.step(.appFirstSnapshot, "claim preloaded live preview")
    return attachment
  }

  func discard() async {
    isAvailable = false
    discardCurrentPreparation()
    await cleanupTask?.value
  }

  private func discardCurrentPreparation() {
    expirationTask?.cancel()
    expirationTask = nil
    guard let preparation else { return }
    self.preparation = nil
    let previous = cleanupTask
    switch preparation {
    case .screenshots(_, let batch, _):
      cleanupTask = Task.immediate {
        await batch.close()
        await previous?.value
      }
    case .livePreview(_, let attachment):
      cleanupTask = Task.immediate {
        await attachment.close()
        await previous?.value
      }
    }
  }
}
