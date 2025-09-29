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

  private var readyContinuation: CheckedContinuation<Media, Error>?
  private var stopContinuation: CheckedContinuation<Error?, Never>?
  private var readyResult: Media?
  private var stopResult: Error??

  init(deviceID: String, adb: ADBService) async throws {
    self.deviceID = deviceID

    let exec = await adb.exec()
    densityScale = try await exec.displayDensity(deviceID: deviceID)
    screenStream = try await exec.startScreenStream(deviceID: deviceID)

    setupDecoder()
    startStreamTask()
  }

  func waitUntilReady() async throws -> Media {
    if let readyResult { return readyResult }
    return try await withCheckedThrowingContinuation { continuation in
      readyContinuation = continuation
    }
  }

  func waitUntilStop() async -> Error? {
    if let stopResult { return stopResult }
    return await withCheckedContinuation { continuation in
      stopContinuation = continuation
    }
  }

  func cancel() {
    Task {
      await finish(with: nil)
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
        let size = CGSize(width: CGFloat(dims.width), height: CGFloat(dims.height))
        let display = DisplayInfo(size: size, densityScale: self.densityScale)
        let media = Media.livePreview(
          capturedAt: Date(),
          display: display
        )
        self.media = media
        self.readyResult = media
        self.readyContinuation?.resume(returning: media)
        self.readyContinuation = nil
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
      do {
        while !Task.isCancelled {
          guard let chunk = try session.read(maxLength: 4096), !chunk.isEmpty else { break }
          decoderRef.value.append(chunk)
        }
        await finish(with: nil)
      } catch {
        await finish(with: error)
      }
    }
  }

  private func finish(with error: Error?) async {
    guard !hasStopped else { return }
    hasStopped = true

    streamTask?.cancel()
    streamTask = nil
    screenStream.close()
    decoder = nil

    stopResult = error
    stopContinuation?.resume(returning: error)
    stopContinuation = nil

    if readyResult == nil {
      readyContinuation?.resume(throwing: error ?? CancellationError())
      readyContinuation = nil
    }
  }
}

private struct UnsafeSendable<T>: @unchecked Sendable {
  let value: T
}
