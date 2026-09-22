@preconcurrency import AVFoundation
import Foundation

/// Owns a preview source, readiness, and samples awaiting a renderer.
@MainActor
final class LivePreviewSession {
  private static let maxPendingSampleCount = 60
  private static let maxPendingSampleByteCount = 2 * 1024 * 1024

  let deviceID: String
  private(set) var readyAt: ContinuousClock.Instant?

  var isReady: Bool {
    media != nil && !hasStopped
  }

  private(set) var media: Media?
  var mediaDidChange: ((Media) -> Void)?
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

  private var densityScale: CGFloat?
  private let source: any LivePreviewFrameSource
  private var pendingSampleBuffers: [CMSampleBuffer] = []
  private var pendingSampleByteCount = 0
  private var needsKeyFrame = true
  private var hasStopped = false

  private var readyContinuations: [CheckedContinuation<Media, Error>] = []
  private var stopContinuation: CheckedContinuation<Error?, Never>?
  private var stopResult: Error??

  init(deviceID: String, densityScale: CGFloat?, source: any LivePreviewFrameSource) {
    self.deviceID = deviceID
    self.densityScale = densityScale
    self.source = source
    source.start { [weak self] event in self?.receive(event) }
  }

  func updateDensityScale(_ densityScale: CGFloat) {
    guard !hasStopped, self.densityScale != densityScale else { return }
    self.densityScale = densityScale
    guard let media else { return }
    let updated = Media.livePreview(
      capturedAt: media.capturedAt,
      display: DisplayInfo(size: media.size, densityScale: densityScale)
    )
    self.media = updated
    mediaDidChange?(updated)
  }

  func waitUntilReady() async throws -> Media {
    if let stopResult { throw stopResult ?? CancellationError() }
    if let media { return media }
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

  private func receive(_ event: LivePreviewFrameEvent) {
    guard !hasStopped else { return }
    switch event {
    case .format(let format):
      let dims = CMVideoFormatDescriptionGetDimensions(format)
      let size = CGSize(width: CGFloat(dims.width), height: CGFloat(dims.height))
      let display = DisplayInfo(size: size, densityScale: densityScale)
      let media = Media.livePreview(capturedAt: Date(), display: display)
      let changed = self.media?.common.display != display
      self.media = media
      readyAt = readyAt ?? .now
      if changed { mediaDidChange?(media) }
      let continuations = readyContinuations
      readyContinuations.removeAll()
      for continuation in continuations {
        continuation.resume(returning: media)
      }
    case .sample(let sample, let isKeyFrame):
      receiveSample(sample, isKeyFrame: isKeyFrame)
    case .stopped(let error):
      finish(with: error)
    }
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

    // Raw frames are independent and may exceed the compressed-stream byte limit.
    if source.hasIndependentFrames {
      pendingSampleBuffers = [sample]
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

  private func finish(with error: Error?) {
    guard !hasStopped else { return }
    hasStopped = true

    source.stop()
    sampleBufferHandler = nil
    mediaDidChange = nil

    stopResult = error
    stopContinuation?.resume(returning: error)
    stopContinuation = nil

    if media == nil {
      let continuations = readyContinuations
      readyContinuations.removeAll()
      for continuation in continuations {
        continuation.resume(throwing: error ?? CancellationError())
      }
    }
  }
}
