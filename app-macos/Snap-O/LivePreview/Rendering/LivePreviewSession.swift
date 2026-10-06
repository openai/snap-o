@preconcurrency import AVFoundation
import Dependencies
import Foundation

/// Owns one preview source and delivers frames independently to its renderers.
@MainActor
final class LivePreviewSession {
  private static let maxPendingSampleCount = 60
  private static let maxPendingSampleByteCount = 2 * 1024 * 1024

  let id = UUID()
  let deviceID: String
  private let clock: AnyClock<Duration>
  private var readyAt: AnyClock<Duration>.Instant?

  var streamingDuration: Duration? {
    readyAt.map { $0.duration(to: clock.now) }
  }

  var isReady: Bool {
    displayInfo != nil && !hasStopped
  }

  private(set) var displayInfo: DisplayInfo?
  var displayDidChange: ((DisplayInfo) -> Void)?
  private struct Renderer {
    let receive: (CMSampleBuffer) -> Void
    var needsKeyFrame: Bool
  }

  private var renderers: [UUID: Renderer] = [:]

  func addRenderer(id: UUID, receive: @escaping (CMSampleBuffer) -> Void) {
    guard !hasStopped else { return }
    let samples = pendingSampleBuffers
    renderers[id] = Renderer(receive: receive, needsKeyFrame: samples.isEmpty)
    if !source.hasIndependentFrames { discardPendingSamples() }
    for sample in samples {
      guard renderers[id] != nil else { return }
      receive(sample)
    }
    if samples.isEmpty { source.requestKeyFrame() }
  }

  func removeRenderer(id: UUID) {
    renderers.removeValue(forKey: id)
    if renderers.isEmpty, !source.hasIndependentFrames {
      discardPendingSamples()
      needsKeyFrame = true
    }
  }

  private var densityScale: CGFloat?
  private let source: any LivePreviewFrameSource
  private var pendingSampleBuffers: [CMSampleBuffer] = []
  private var pendingSampleByteCount = 0
  private var needsKeyFrame = true
  private var hasStopped = false
  #if PERF_TRACING
  private var loggedFirstSample = false
  #endif

  private var readyContinuations: [CheckedContinuation<DisplayInfo, Error>] = []
  private var stopContinuations: [CheckedContinuation<Void, Never>] = []
  private var stopError: Error?

  init(deviceID: String, densityScale: CGFloat?, source: any LivePreviewFrameSource) {
    @Dependency(\.continuousClock)
    var clock
    self.clock = AnyClock(clock)
    self.deviceID = deviceID
    self.densityScale = densityScale
    self.source = source
    #if PERF_TRACING
    Perf.startupEvent("session source start", deviceID: deviceID)
    #endif
    source.start { [weak self] event in self?.receive(event) }
  }

  func updateDensityScale(_ densityScale: CGFloat) {
    guard !hasStopped, self.densityScale != densityScale else { return }
    self.densityScale = densityScale
    guard let displayInfo else { return }
    let updated = DisplayInfo(size: displayInfo.size, densityScale: densityScale)
    self.displayInfo = updated
    displayDidChange?(updated)
  }

  func waitUntilReady() async throws -> DisplayInfo {
    if hasStopped { throw stopError ?? CancellationError() }
    if let displayInfo { return displayInfo }
    return try await withCheckedThrowingContinuation { continuation in
      readyContinuations.append(continuation)
    }
  }

  func waitUntilStop() async -> Error? {
    if !hasStopped {
      await withCheckedContinuation { stopContinuations.append($0) }
    }
    await source.waitUntilStopped()
    return stopError
  }

  func cancel() {
    finish(with: nil)
  }

  private func receive(_ event: LivePreviewFrameEvent) {
    guard !hasStopped else { return }
    switch event {
    case .density(let density):
      updateDensityScale(density)
    case .format(let format):
      #if PERF_TRACING
      Perf.startupEvent("session format received", deviceID: deviceID)
      #endif

      for id in renderers.keys {
        renderers[id]?.needsKeyFrame = true
      }
      discardPendingSamples()
      needsKeyFrame = true
      let dims = CMVideoFormatDescriptionGetDimensions(format)
      let size = CGSize(width: CGFloat(dims.width), height: CGFloat(dims.height))
      let display = DisplayInfo(size: size, densityScale: densityScale)
      let changed = displayInfo != display
      displayInfo = display
      readyAt = readyAt ?? clock.now
      if changed { displayDidChange?(display) }
      let continuations = readyContinuations
      readyContinuations.removeAll()
      for continuation in continuations {
        continuation.resume(returning: display)
      }
    case .sample(let sample, let isKeyFrame):
      receiveSample(sample, isKeyFrame: isKeyFrame)
    case .stopped(let error):
      finish(with: error)
    }
  }

  private func receiveSample(_ sample: CMSampleBuffer, isKeyFrame: Bool) {
    guard !hasStopped else { return }

    #if PERF_TRACING
    if !loggedFirstSample {
      loggedFirstSample = true
      Perf.startupEvent("session first sample", deviceID: deviceID)
    }
    #endif
    if isKeyFrame {
      needsKeyFrame = false
      for id in renderers.keys {
        renderers[id]?.needsKeyFrame = false
      }
      if renderers.isEmpty { discardPendingSamples() }
    }
    guard !needsKeyFrame else { return }

    // Keep one independent frame so a new window can show an idle emulator.
    if source.hasIndependentFrames { pendingSampleBuffers = [sample] }
    if !renderers.isEmpty {
      for (id, renderer) in Array(renderers) {
        guard renderers[id] != nil, !renderer.needsKeyFrame else { continue }
        renderer.receive(sample)
      }
      return
    }
    if source.hasIndependentFrames { return }

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
    renderers.removeAll()
    discardPendingSamples()
    displayDidChange = nil

    stopError = error
    let continuations = stopContinuations
    stopContinuations.removeAll()
    for continuation in continuations {
      continuation.resume()
    }

    if displayInfo == nil {
      let continuations = readyContinuations
      readyContinuations.removeAll()
      for continuation in continuations {
        continuation.resume(throwing: error ?? CancellationError())
      }
    }
  }
}
