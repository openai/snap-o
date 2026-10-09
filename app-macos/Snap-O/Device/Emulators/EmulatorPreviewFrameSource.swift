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
  private var startupDeadline: EmulatorPreviewStartupDeadline?
  private var currentRequest = FrameRequest(size: .native)
  private let requests = AsyncStream<FrameRequest>.makeStream(bufferingPolicy: .bufferingNewest(1))

  private struct FrameRequest {
    let id = UUID()
    let size: LivePreviewFrameSize
  }

  func setFrameSize(_ size: LivePreviewFrameSize) {
    guard !hasStopped, size != currentRequest.size else { return }
    currentRequest = FrameRequest(size: size)
    startupDeadline?.setActive(size != .inactive)
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
    startupDeadline = EmulatorPreviewStartupDeadline { [weak self] in
      self?.stop()
      deliver(.stopped(EmulatorPreviewError(message: "The emulator did not provide a preview frame in time.")))
    }
    startupDeadline?.setActive(currentRequest.size != .inactive)
    let receive: @MainActor @Sendable (LivePreviewFrameEvent) -> Void = { [weak self] event in
      guard self?.hasStopped == false else { return }
      switch event {
      case .sample, .stopped: self?.startupDeadline?.finish()
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
    startupDeadline?.finish()
    requests.continuation.finish()
    task?.cancel()
  }

  func waitUntilStopped() async {
    await task?.value
    await startupDeadline?.waitUntilStopped()
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
    size requestedSize: LivePreviewFrameSize,
    deliver: @escaping @MainActor @Sendable (LivePreviewFrameEvent) -> Void
  ) async throws {
    try await EmulatorPreviewStream.run(requestedSize: requestedSize) {
      try await readDisplaySize(target: target)
    } receiveFrames: { size, nativeSize in
      try await requestScreenshots(client: client, metadata: metadata, size: size) { response in
        let frames = EmulatorPreviewFrameBuilder()
        var geometry = EmulatorPreviewGeometry(requestedSize: requestedSize, nativeSize: nativeSize)
        for try await image in response.messages {
          try Task.checkCancellation()
          guard let sample = try frames.makeSample(from: image) else { continue }
          let update = try await updateGeometry(&geometry, for: image.format, target: target)
          if let change = await deliverFrame(sample, update: update, deliver: deliver) {
            return change
          }
        }
        return nil
      }
    }
  }

  private nonisolated static func updateGeometry(
    _ geometry: inout EmulatorPreviewGeometry,
    for format: EmulatorPreview_ImageFormat,
    target: DeviceTarget
  ) async throws -> EmulatorPreviewGeometry.Update {
    let frame = EmulatorPreviewGeometry.Frame(format)
    if geometry.needsNativeSize(for: frame) {
      geometry.nativeSize = try await EmulatorPreviewStream.readSize { try await readDisplaySize(target: target) }
    }
    try Task.checkCancellation()
    return geometry.update(frame)
  }

  private nonisolated static func deliverFrame(
    _ sample: CMSampleBuffer,
    update: EmulatorPreviewGeometry.Update,
    deliver: @escaping @MainActor @Sendable (LivePreviewFrameEvent) -> Void
  ) async -> EmulatorPreviewStream.DisplayChange? {
    switch update {
    case .unchanged: break
    case .format(let displaySize):
      if let description = CMSampleBufferGetFormatDescription(sample) {
        await deliver(.format(description, displaySize: displaySize))
      }
    case .restart(let nativeSize):
      return EmulatorPreviewStream.DisplayChange(size: nativeSize)
    }
    await deliver(.sample(sample, isKeyFrame: true))
    return nil
  }

  private nonisolated static func requestScreenshots<Result: Sendable>(
    client: GRPCClient<HTTP2ClientTransport.WrappedChannel>,
    metadata: Metadata,
    size: LivePreviewFrameSize,
    onResponse: @escaping @Sendable (StreamingClientResponse<EmulatorPreview_Image>) async throws -> Result
  ) async throws -> Result {
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
    return try await client.serverStreaming(
      request: request,
      descriptor: MethodDescriptor(
        fullyQualifiedService: "android.emulation.control.EmulatorController",
        method: "streamScreenshot"
      ),
      serializer: EmulatorProtobufCodec<EmulatorPreview_ImageFormat>(),
      deserializer: EmulatorProtobufCodec<EmulatorPreview_Image>(),
      options: options,
      onResponse: onResponse
    )
  }

  private nonisolated static func readDisplaySize(target: DeviceTarget) async throws -> CGSize? {
    let dimensions = try await ADBClient().bound(to: target).withTimeout(.seconds(2)).displaySize(deviceID: target.serial)
    let parts = dimensions.split(separator: "x").compactMap { Int($0) }
    guard parts.count == 2, parts.allSatisfy({ $0 > 0 && $0 <= 8192 }) else { return nil }
    return CGSize(width: parts[0], height: parts[1])
  }
}

private extension EmulatorPreviewGeometry.Frame {
  init(_ format: EmulatorPreview_ImageFormat) {
    self.init(
      size: CGSize(width: Int(format.width), height: Int(format.height)),
      rotation: format.rotation.rotation.rawValue,
      display: format.display,
      // Preserve fold and display-mode metadata, ignoring continuously changing sensor angles.
      configuration: format.unknownFields.data
    )
  }
}

private extension EmulatorPreviewFrameBuilder {
  func makeSample(from image: EmulatorPreview_Image) throws -> CMSampleBuffer? {
    let width = Int(image.format.width)
    let height = Int(image.format.height)
    // The emulator reports an inactive display with an empty image.
    guard width != 0, height != 0 else { return nil }
    guard image.format.format == .rgb888 else {
      throw EmulatorPreviewError(message: "The emulator returned an unsupported pixel format.")
    }
    return try makeSample(rgb: image.image, width: width, height: height, timestamp: image.timestampUs)
  }
}
