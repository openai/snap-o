@preconcurrency import AVFoundation
import Dependencies
import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2TransportServices
import SwiftProtobuf

@MainActor
final class EmulatorPreviewFrameSource: LivePreviewFrameSource {
  let hasIndependentFrames = true
  private let target: DeviceTarget
  private let clock: AnyClock<Duration>
  private var hasStarted = false
  private var hasStopped = false
  private var invalidationHandler: UUID?
  private var task: Task<Void, Never>?
  private var startupTimeout: Task<Void, Never>?

  init(target: DeviceTarget) {
    @Dependency(\.continuousClock)
    var clock
    self.clock = AnyClock(clock)
    self.target = target
  }

  private static func endpoint(for deviceID: String, clock: AnyClock<Duration>) async throws -> EmulatorGRPCEndpoint {
    let client = AndroidHostClient()
    defer { client.close() }
    while true {
      try Task.checkCancellation()
      if let endpoint = try await client.previewEndpoint(deviceID) { return endpoint }
      // Registration and authentication can lag behind ADB discovery.
      try await clock.sleep(for: .milliseconds(250))
    }
  }

  func start(deliver: @escaping @MainActor @Sendable (LivePreviewFrameEvent) -> Void) {
    guard !hasStarted, !hasStopped else { return }
    hasStarted = true
    let clock = clock
    let target = target
    let deviceID = target.serial
    do {
      invalidationHandler = try target.onInvalidation { [weak self] in
        Task { @MainActor in
          guard let self, !self.hasStopped else { return }
          self.stop()
          deliver(.stopped(ADBError.protocolFailure("The device connection is no longer available.")))
        }
      }
    } catch {
      deliver(.stopped(error))
      return
    }
    // Bound startup without limiting a healthy stream’s lifetime.
    startupTimeout = Task { [weak self] in
      do { try await clock.sleep(for: .seconds(15)) } catch { return }
      self?.stop()
      deliver(.stopped(EmulatorPreviewError(message: "The emulator did not provide a preview frame in time.")))
    }
    let receive: @MainActor @Sendable (LivePreviewFrameEvent) -> Void = { [weak self] event in
      guard self?.hasStopped == false else { return }
      switch event {
      case .sample, .stopped: self?.startupTimeout?.cancel()
      case .format, .density: break
      }
      if target.isValid {
        deliver(event)
      } else {
        deliver(.stopped(ADBError.protocolFailure("The device connection is no longer available.")))
      }
    }
    task = Task.detached(priority: .userInitiated) {
      do {
        #if PERF_TRACING
        Perf.startupEvent("emulator endpoint lookup begin", deviceID: deviceID)
        #endif
        _ = try target.requireTransport(for: deviceID)
        let endpoint = try await Self.endpoint(for: deviceID, clock: clock)
        try Task.checkCancellation()
        _ = try target.requireTransport(for: deviceID)
        #if PERF_TRACING
        Perf.startupEvent("emulator endpoint lookup end", deviceID: deviceID)
        #endif

        try await Self.stream(target: target, endpoint: endpoint, deliver: receive)
        if !Task.isCancelled {
          await receive(.stopped(EmulatorPreviewError(message: "The emulator preview stream ended.")))
        }
      } catch {
        await receive(.stopped(Task.isCancelled ? nil : error))
      }
    }
  }

  func stop() {
    hasStopped = true
    if let invalidationHandler { target.removeInvalidationHandler(invalidationHandler) }
    invalidationHandler = nil
    startupTimeout?.cancel()
    task?.cancel()
  }

  func waitUntilStopped() async {
    await task?.value
    await startupTimeout?.value
  }

  private nonisolated static func stream(
    target: DeviceTarget,
    endpoint: EmulatorGRPCEndpoint,
    deliver: @escaping @MainActor @Sendable (LivePreviewFrameEvent) -> Void
  ) async throws {
    try await EmulatorGRPCConnection.withDevice(target: target, endpoint: endpoint) { client, metadata in
      var format = EmulatorPreview_ImageFormat()
      format.format = .rgba8888
      // Zero dimensions request full emulator frames without preview-size scaling.
      let request = ClientRequest(message: format, metadata: metadata)
      var options = CallOptions.defaults
      options.waitForReady = true
      options.maxResponseMessageBytes = 64 * 1024 * 1024 + 4096
      // NIO transport 2.10 also uses the request limit when decoding responses.
      options.maxRequestMessageBytes = options.maxResponseMessageBytes
      try await client.serverStreaming(
        request: request,
        descriptor: MethodDescriptor(
          fullyQualifiedService: "android.emulation.control.EmulatorController",
          method: "streamScreenshot"
        ),
        serializer: EmulatorProtobufCodec<EmulatorPreview_ImageFormat>(),
        deserializer: EmulatorProtobufCodec<EmulatorPreview_Image>(),
        options: options
      ) { response in
        let frames = EmulatorPreviewFrameBuilder()
        var previousSize: CGSize?
        for try await image in response.messages {
          try Task.checkCancellation()
          let width = Int(image.format.width)
          let height = Int(image.format.height)
          // The emulator reports an inactive display with an empty image.
          guard width != 0, height != 0 else { continue }
          guard image.format.format == .rgba8888 else {
            throw EmulatorPreviewError(message: "The emulator returned an unsupported pixel format.")
          }
          guard let sample = try frames.makeSample(
            rgba: image.image, width: width, height: height, timestamp: image.timestampUs
          ) else { continue }
          let size = CGSize(width: width, height: height)
          if size != previousSize, let description = CMSampleBufferGetFormatDescription(sample) {
            await deliver(.format(description))
            previousSize = size
          }
          await deliver(.sample(sample, isKeyFrame: true))
        }
      }
    }
  }
}
