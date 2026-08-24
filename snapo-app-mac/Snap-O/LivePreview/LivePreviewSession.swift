@preconcurrency import AVFoundation
import Foundation
import SnapODeviceClient

/// Owns one device-side live-preview process and its decoded frame stream.
@MainActor
final class LivePreviewSession {
  private static let maxPendingSampleCount = 60
  private static let maxPendingSampleByteCount = 2 * 1024 * 1024

  let deviceID: String

  var media: Media?
  var sampleBufferHandler: ((CMSampleBuffer) -> Void)? {
    didSet {
      guard let sampleBufferHandler else {
        discardPendingSamples()
        needsKeyFrame = true
        return
      }

      let pendingSamples = pendingSampleBuffers
      discardPendingSamples()
      for sample in pendingSamples {
        sampleBufferHandler(sample)
      }
    }
  }

  private let densityScale: CGFloat
  private let screenStream: ScreenStreamSession
  private var decoder: H264StreamDecoder?
  private var pendingSampleBuffers: [CMSampleBuffer] = []
  private var pendingSampleByteCount = 0
  private var needsKeyFrame = true
  private var streamTask: Task<Void, Never>?
  private var hasStopped = false

  private var readyContinuations: [CheckedContinuation<Media, Error>] = []
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
    if let stopResult { throw stopResult ?? CancellationError() }
    return try await withCheckedThrowingContinuation { continuation in
      readyContinuations.append(continuation)
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
    let decoder = H264StreamDecoder { [weak self] sample, isKeyFrame in
      guard let self else { return }
      let boxed = UnsafeSendable(value: sample)
      DispatchQueue.main.async {
        self.receiveSample(boxed.value, isKeyFrame: isKeyFrame)
      }
    } formatHandler: { [weak self] format in
      guard let self else { return }
      let dims = CMVideoFormatDescriptionGetDimensions(format)
      DispatchQueue.main.async {
        guard !self.hasStopped else { return }
        let size = CGSize(width: CGFloat(dims.width), height: CGFloat(dims.height))
        let display = DisplayInfo(size: size, densityScale: self.densityScale)
        let media = Media.livePreview(
          capturedAt: Date(),
          display: display
        )
        self.media = media
        self.readyResult = media
        let continuations = self.readyContinuations
        self.readyContinuations.removeAll()
        for continuation in continuations {
          continuation.resume(returning: media)
        }
      }
    }
    self.decoder = decoder
  }

  private func receiveSample(_ sample: CMSampleBuffer, isKeyFrame: Bool) {
    guard !hasStopped else { return }

    if isKeyFrame {
      needsKeyFrame = false
      if sampleBufferHandler == nil {
        discardPendingSamples()
      }
    }
    guard !needsKeyFrame else { return }

    if let sampleBufferHandler {
      sampleBufferHandler(sample)
      return
    }

    let sampleByteCount = CMSampleBufferGetTotalSampleSize(sample)
    guard sampleByteCount <= Self.maxPendingSampleByteCount,
          pendingSampleBuffers.count < Self.maxPendingSampleCount,
          pendingSampleByteCount <= Self.maxPendingSampleByteCount - sampleByteCount else {
      discardPendingSamples()
      needsKeyFrame = true
      return
    }

    pendingSampleBuffers.append(sample)
    pendingSampleByteCount += sampleByteCount
  }

  private func discardPendingSamples() {
    pendingSampleBuffers.removeAll(keepingCapacity: true)
    pendingSampleByteCount = 0
  }

  private func startStreamTask() {
    guard let decoder else { return }
    let session = screenStream
    streamTask = Task.detached(priority: .userInitiated) { [weak self] in
      guard let self else { return }
      let streamError: Error?
      do {
        while !Task.isCancelled {
          guard let chunk = try session.read(maxLength: 64 * 1024), !chunk.isEmpty else { break }
          decoder.append(chunk)
        }
        streamError = nil
      } catch {
        streamError = error
      }

      decoder.finish()
      DispatchQueue.main.async {
        self.finish(with: streamError)
      }
    }
  }

  private func finish(with error: Error?) {
    guard !hasStopped else { return }
    hasStopped = true

    streamTask?.cancel()
    streamTask = nil
    screenStream.close()
    decoder = nil
    sampleBufferHandler = nil

    stopResult = error
    stopContinuation?.resume(returning: error)
    stopContinuation = nil

    if readyResult == nil {
      let continuations = readyContinuations
      readyContinuations.removeAll()
      for continuation in continuations {
        continuation.resume(throwing: error ?? CancellationError())
      }
    }
  }
}

private struct UnsafeSendable<T>: @unchecked Sendable {
  let value: T
}
