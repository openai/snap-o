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
  private var currentRequest = FrameRequest(size: .native)
  private let requests = AsyncStream<FrameRequest>.makeStream(bufferingPolicy: .bufferingNewest(1))

  private struct FrameRequest {
    let id = UUID()
    let size: LivePreviewFrameSize
  }

  func setFrameSize(_ size: LivePreviewFrameSize) {
    guard !hasStopped, size != currentRequest.size else { return }
    currentRequest = FrameRequest(size: size)
    requests.continuation.yield(currentRequest)
  }

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
    requests.continuation.yield(currentRequest)
    let sizes = requests.stream
    let receiveFrame: @MainActor @Sendable (LivePreviewFrameEvent, UUID) -> Void = { [weak self] event, requestID in
      guard self?.currentRequest.id == requestID else { return }
      receive(event)
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

        try await Self.stream(target: target, endpoint: endpoint, sizes: sizes, deliver: receiveFrame)
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
    requests.continuation.finish()
    task?.cancel()
  }

  func waitUntilStopped() async {
    await task?.value
    await startupTimeout?.value
  }

  private nonisolated static func nextRequest(in sizes: AsyncStream<FrameRequest>) async -> FrameRequest? {
    for await request in sizes {
      return request
    }
    return nil
  }

  private nonisolated static func stream(
    target: DeviceTarget,
    endpoint: EmulatorGRPCEndpoint,
    sizes: AsyncStream<FrameRequest>,
    deliver: @escaping @MainActor @Sendable (LivePreviewFrameEvent, UUID) -> Void
  ) async throws {
    try await EmulatorGRPCConnection.withDevice(target: target, endpoint: endpoint) { client, metadata in
      var next = await nextRequest(in: sizes)
      while let request = next {
        try Task.checkCancellation()
        if request.size == .inactive {
          next = await nextRequest(in: sizes)
          continue
        }
        next = try await withThrowingTaskGroup(of: FrameRequest?.self) { group in
          defer { group.cancelAll() }
          group.addTask {
            try await streamFrames(target: target, client: client, metadata: metadata, size: request.size) { event in
              deliver(event, request.id)
            }
            throw EmulatorPreviewError(message: "The emulator preview stream ended.")
          }
          group.addTask { await nextRequest(in: sizes) }
          guard let next = try await group.next() else { return nil }
          return next
        }
      }
    }
  }

  private nonisolated static func streamFrames(
    target: DeviceTarget,
    client: GRPCClient<HTTP2ClientTransport.WrappedChannel>,
    metadata: Metadata,
    size: LivePreviewFrameSize,
    deliver: @escaping @MainActor @Sendable (LivePreviewFrameEvent) -> Void
  ) async throws {
    var format = EmulatorPreview_ImageFormat()
    format.format = .rgb888
    if case .preview(let pixels) = size {
      format.width = UInt32(pixels.width)
      format.height = UInt32(pixels.height)
    }
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
      var previousFormat: EmulatorPreview_ImageFormat?
      for try await image in response.messages {
        try Task.checkCancellation()
        let width = Int(image.format.width)
        let height = Int(image.format.height)
        // The emulator reports an inactive display with an empty image.
        guard width != 0, height != 0 else { continue }
        guard image.format.format == .rgb888 else {
          throw EmulatorPreviewError(message: "The emulator returned an unsupported pixel format.")
        }
        guard let sample = try frames.makeSample(
          rgb: image.image, width: width, height: height, timestamp: image.timestampUs
        ) else { continue }
        var geometry = image.format
        // Sensor angles can change every frame without changing display geometry.
        geometry.rotation.unknownFields = SwiftProtobuf.UnknownStorage()
        if geometry != previousFormat, let description = CMSampleBufferGetFormatDescription(sample) {
          // Input uses native coordinates even when the preview image is scaled.
          let dimensions = try await ADBClient().bound(to: target).withTimeout(.seconds(2)).displaySize(deviceID: target.serial)
          let parts = dimensions.split(separator: "x").compactMap { Int($0) }
          guard parts.count == 2, parts.allSatisfy({ $0 > 0 && $0 <= 8192 }) else {
            throw EmulatorPreviewError(message: "The emulator returned an invalid display size.")
          }
          let displaySize = CGSize(width: parts[0], height: parts[1])
          await deliver(.format(description, displaySize: displaySize))
          previousFormat = geometry
        }
        await deliver(.sample(sample, isKeyFrame: true))
      }
    }
  }
}
