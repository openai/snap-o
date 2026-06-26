import AppKit
@preconcurrency import AVFoundation
import Foundation
import ImageIO
import SnapODeviceClient

/// Owns one device-side live-preview process and its decoded frame stream.
@MainActor
final class LivePreviewSession {
  private static let initialFrameTimeout: Duration = .seconds(2)

  let deviceID: String
  private(set) var initialFrame: CGImage?

  var media: Media?
  var initialFrameHandler: ((CGImage) -> Void)? {
    didSet {
      if let initialFrame {
        initialFrameHandler?(initialFrame)
      }
    }
  }

  var sampleBufferHandler: ((CMSampleBuffer) -> Void)?

  private let densityScale: CGFloat
  private let screenStream: ScreenStreamSession
  private var decoder: H264StreamDecoder?
  private var initialFrameTask: Task<Void, Never>?
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
    startInitialFrameTask(using: exec)
  }

  private static func captureInitialFrame(deviceID: String, using exec: ADBClient) async throws -> CGImage? {
    let timeout = initialFrameTimeout
    let data = try await withThrowingTaskGroup(of: Data?.self, returning: Data?.self) { group in
      group.addTask {
        do {
          return try await exec.screencapPNG(deviceID: deviceID)
        } catch {
          try Task.checkCancellation()
          return nil
        }
      }
      group.addTask {
        try await Task.sleep(for: timeout)
        return nil
      }

      defer { group.cancelAll() }
      guard let result = try await group.next() else { return nil }
      return result
    }
    return data.flatMap(decodeInitialFrame)
  }

  private static func decodeInitialFrame(from data: Data) -> CGImage? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(source, 0, nil)
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

  func discardInitialFrame() {
    initialFrame = nil
    initialFrameHandler = nil
  }

  private func startInitialFrameTask(using exec: ADBClient) {
    initialFrameTask = Task { [weak self] in
      guard let self else { return }
      defer { initialFrameTask = nil }

      do {
        guard let frame = try await Self.captureInitialFrame(deviceID: deviceID, using: exec),
              !hasStopped else { return }
        initialFrame = frame
        initialFrameHandler?(frame)
      } catch {
        // The initial frame is best-effort; live preview continues without it.
      }
    }
  }

  private func setupDecoder() {
    let decoder = H264StreamDecoder { [weak self] sample in
      guard let self else { return }
      let boxed = UnsafeSendable(value: sample)
      Task { @MainActor in
        guard !self.hasStopped else { return }
        self.sampleBufferHandler?(boxed.value)
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

  private func finish(with error: Error?) {
    guard !hasStopped else { return }
    hasStopped = true

    streamTask?.cancel()
    streamTask = nil
    initialFrameTask?.cancel()
    initialFrameTask = nil
    screenStream.close()
    decoder = nil
    initialFrame = nil
    initialFrameHandler = nil
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
