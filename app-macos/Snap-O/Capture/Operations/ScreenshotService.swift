import CoreGraphics
import Foundation

/// Captures one device. The caller owns batching and history.
struct ScreenshotService {
  private let adb: ADBService
  private let fileStore: FileStore
  private let timestampSource = CaptureTimestampSource()

  init(adb: ADBService, fileStore: FileStore) {
    self.adb = adb
    self.fileStore = fileStore
  }

  func capture(device: Device) async throws -> CaptureMedia {
    try await ScreenshotDeadline.run {
      try await captureImage(device: device)
    }
  }

  private func captureImage(device: Device) async throws -> CaptureMedia {
    let target = try device.requireConnection()
    let exec = await adb.exec().bound(to: target)
    async let dataTask = exec.screencapPNG(deviceID: device.id)
    async let densityTask = try? await exec.displayDensity(deviceID: device.id)
    let data = try await dataTask
    let capturedAt = await timestampSource.next()
    let destination = fileStore.makePreviewDestination(
      deviceID: device.id, capturedAt: capturedAt, kind: .image
    )
    let writeTask = Task(priority: .userInitiated) { () throws -> CGSize in
      let size = try pngSize(from: data)
      try data.write(to: destination, options: [.atomic])
      return size
    }
    let size = try await writeTask.value
    let densityValue = await densityTask
    return CaptureMedia(
      device: device,
      media: .image(
        url: destination,
        capturedAt: capturedAt,
        display: DisplayInfo(size: size, densityScale: densityValue.map { CGFloat($0) })
      )
    )
  }
}
