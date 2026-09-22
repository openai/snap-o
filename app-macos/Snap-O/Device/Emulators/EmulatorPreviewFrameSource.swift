@preconcurrency import AVFoundation
import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2TransportServices
import SwiftProtobuf

@MainActor
final class EmulatorPreviewFrameSource: LivePreviewFrameSource {
  let hasIndependentFrames = true
  private let deviceID: String
  private var task: Task<Void, Never>?

  init(deviceID: String) {
    self.deviceID = deviceID
  }

  private static func endpoint(for deviceID: String) async throws -> EmulatorGRPCEndpoint {
    let client = EmulatorClient()
    defer { client.close() }
    let deadline = ContinuousClock.now + .seconds(15)
    while true {
      try Task.checkCancellation()
      do {
        return try await client.previewEndpoint(deviceID)
      } catch {
        try Task.checkCancellation()
        guard ContinuousClock.now < deadline else { throw error }
        // Registration and authentication can lag behind ADB discovery.
        try await Task.sleep(for: .milliseconds(250))
      }
    }
  }

  func start(deliver: @escaping @MainActor @Sendable (LivePreviewFrameEvent) -> Void) {
    let deviceID = deviceID
    task = Task.detached(priority: .userInitiated) {
      do {
        let endpoint = try await Self.endpoint(for: deviceID)
        try await Self.stream(endpoint: endpoint, deliver: deliver)
        if !Task.isCancelled {
          await deliver(.stopped(EmulatorPreviewError(message: "The emulator preview stream ended.")))
        }
      } catch {
        await deliver(.stopped(Task.isCancelled ? nil : error))
      }
    }
  }

  func stop() {
    task?.cancel()
    task = nil
  }

  private nonisolated static func stream(
    endpoint: EmulatorGRPCEndpoint,
    deliver: @escaping @MainActor @Sendable (LivePreviewFrameEvent) -> Void
  ) async throws {
    let transport = try HTTP2ClientTransport.TransportServices(
      target: .ipv4(address: "127.0.0.1", port: endpoint.port),
      transportSecurity: .plaintext
    )
    try await withGRPCClient(transport: transport) { client in
      var format = EmulatorPreview_ImageFormat()
      format.format = .rgba8888
      // Zero dimensions request full emulator frames without preview-size scaling.
      var request = ClientRequest(message: format)
      if let token = endpoint.token {
        request.metadata.addString("Bearer " + token, forKey: "authorization")
      }
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
        serializer: PreviewProtobufCodec<EmulatorPreview_ImageFormat>(),
        deserializer: PreviewProtobufCodec<EmulatorPreview_Image>(),
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

private struct PreviewProtobufCodec<Message: SwiftProtobuf.Message>: MessageSerializer, MessageDeserializer {
  func serialize<Bytes: GRPCContiguousBytes>(_ message: Message) throws -> Bytes {
    try Bytes(message.serializedData())
  }

  func deserialize(_ bytes: some GRPCContiguousBytes) throws -> Message {
    try bytes.withUnsafeBytes { buffer in
      guard let baseAddress = buffer.baseAddress else { return try Message(serializedBytes: Data()) }
      // Borrow transport storage only for synchronous decoding; protobuf owns the decoded fields.
      let data = Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: baseAddress), count: buffer.count, deallocator: .none)
      return try Message(serializedBytes: data)
    }
  }
}
