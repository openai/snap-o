@preconcurrency import AVFoundation
import Foundation
import SnapODeviceClient

/// Owns one device-side live-preview process and its decoded frame stream.
@MainActor
final class LivePreviewSession {
  let deviceID: String

  var media: Media?
  var sampleBufferHandler: ((CMSampleBuffer) -> Void)? {
    didSet {
      guard let sampleBufferHandler else { return }

      let pendingSamples = pendingSampleBuffers
      pendingSampleBuffers.removeAll(keepingCapacity: true)
      for sample in pendingSamples {
        sampleBufferHandler(sample)
      }
    }
  }

  private let densityScale: CGFloat
  private let screenStream: ScreenStreamSession
  private var decoder: H264StreamDecoder?
  private var pendingSampleBuffers: [CMSampleBuffer] = []
  private var streamTask: Task<Void, Never>?
  private var hasStopped = false

  private var readyContinuation: CheckedContinuation<Media, Error>?
  private var stopContinuation: CheckedContinuation<Error?, Never>?
  private var readyResult: Media?
  private var stopResult: Error??

  init(deviceID: String, adb: ADBService) async throws {
    self.deviceID = deviceID

    let exec = await adb.exec()
    async let densityValue = exec.displayDensity(deviceID: deviceID)
    async let startedStream = exec.startScreenStream(deviceID: deviceID)
    densityScale = try await CGFloat(densityValue)
    screenStream = try await startedStream

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
    finish(with: nil)
  }

  private func setupDecoder() {
    let decoder = H264StreamDecoder { [weak self] sample in
      guard let self else { return }
      let boxed = UnsafeSendable(value: sample)
      Task { @MainActor in
        guard !self.hasStopped else { return }
        if let sampleBufferHandler = self.sampleBufferHandler {
          sampleBufferHandler(boxed.value)
        } else {
          self.pendingSampleBuffers.append(boxed.value)
        }
      }
    } formatHandler: { [weak self] format in
      guard let self else { return }
      let dims = CMVideoFormatDescriptionGetDimensions(format)
      Task { @MainActor in
        guard !self.hasStopped else { return }
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
    let session = screenStream
    streamTask = Task.detached(priority: .userInitiated) { [weak self] in
      guard let self else { return }
      let streamError: Error?
      do {
        while !Task.isCancelled {
          guard let chunk = try session.read(maxLength: 4096), !chunk.isEmpty else { break }
          decoder.append(chunk)
        }
        streamError = nil
      } catch {
        streamError = error
      }

      decoder.finish()
      await finish(with: streamError)
    }
  }

  private func finish(with error: Error?) {
    guard !hasStopped else { return }
    hasStopped = true

    streamTask?.cancel()
    streamTask = nil
    screenStream.close()
    decoder?.finish()
    decoder = nil
    pendingSampleBuffers.removeAll(keepingCapacity: false)
    sampleBufferHandler = nil

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
