import AppKit
@preconcurrency import AVFoundation
import Foundation

@MainActor
final class LivePreviewSession {
  let deviceID: String

  var media: Media?
  var sampleBufferHandler: ((CMSampleBuffer) -> Void)?

  private let densityScale: CGFloat
  private let screenStream: ScreenStreamSession
  private var decoder: H264StreamDecoder?
  private var streamTask: Task<Void, Never>?
  private var hasStopped = false

  private let onReady: (Media) -> Void
  private let onStop: (Error?, Bool) -> Void

  init(
    deviceID: String,
    adb: ADBClient,
    onReady: @escaping (Media) -> Void,
    onStop: @escaping (Error?, Bool) -> Void
  ) async throws {
    self.deviceID = deviceID
    self.onReady = onReady
    self.onStop = onStop

    densityScale = try await adb.screenDensityScale(deviceID: deviceID)
    screenStream = try await adb.startScreenStream(deviceID: deviceID)

    setupDecoder()
    startStreamTask()
  }

  func cancel(refreshPreview: Bool) {
    Task {
      await finish(with: nil, refreshPreview: refreshPreview)
    }
  }

  private func setupDecoder() {
    let decoder = H264StreamDecoder { [weak self] sample in
      guard let self else { return }
      let boxed = UnsafeSendable(value: sample)
      Task { @MainActor in
        self.sampleBufferHandler?(boxed.value)
      }
    } formatHandler: { [weak self] format in
      guard let self else { return }
      let dims = CMVideoFormatDescriptionGetDimensions(format)
      Task { @MainActor in
        let media = Media(
          kind: .video,
          url: URL(fileURLWithPath: "/dev/null"),
          capturedAt: Date(),
          width: CGFloat(dims.width),
          height: CGFloat(dims.height),
          densityScale: self.densityScale
        )
        self.media = media
        self.onReady(media)
      }
    }
    self.decoder = decoder
  }

  private func startStreamTask() {
    guard let decoder else { return }
    let decoderRef = UnsafeSendable(value: decoder)
    let session = screenStream
    streamTask = Task.detached(priority: .userInitiated) { [weak self] in
      guard let self else { return }
      let handle = session.stdoutPipe.fileHandleForReading
      do {
        while !Task.isCancelled {
          guard let data = try handle.read(upToCount: 4096), !data.isEmpty else { break }
          decoderRef.value.append(data)
        }
        await finish(with: nil, refreshPreview: false)
      } catch {
        await finish(with: error, refreshPreview: false)
      }
    }
  }

  private func finish(with error: Error?, refreshPreview: Bool) async {
    guard !hasStopped else { return }
    hasStopped = true

    streamTask?.cancel()
    streamTask = nil
    screenStream.process.terminate()
    decoder = nil

    onStop(error, refreshPreview)
  }
}

private struct UnsafeSendable<T>: @unchecked Sendable {
  let value: T
}
