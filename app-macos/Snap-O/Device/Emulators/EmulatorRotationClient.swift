import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2TransportServices
import SwiftProtobuf

/// Uses the same virtual-device rotation model as Android Studio.
@MainActor
struct EmulatorRotationClient {
  static func rotate(target: DeviceTarget, left: Bool) async throws {
    try await connect(target: target) { client, metadata in
      let current = try await read(client, metadata: metadata)
      let orientation = LivePreviewRotation.target(from: current, left: left)
      var value = EmulatorPreview_PhysicalModelValue()
      value.target = .rotation
      value.value.data = [0, 0, [0, 90, -180, -90][orientation]]
      _ = try target.requireTransport(for: target.serial)
      try Task.checkCancellation()
      try await client.unary(
        request: ClientRequest(message: value, metadata: metadata),
        descriptor: method("setPhysicalModel"),
        serializer: EmulatorProtobufCodec<EmulatorPreview_PhysicalModelValue>(),
        deserializer: EmulatorProtobufCodec<Google_Protobuf_Empty>(),
        options: options
      ) { _ = try $0.message }
      // The model interpolates toward its target. Serialize the next click after it settles.
      for _ in 0 ..< 30 {
        let model = try await read(client, metadata: metadata)
        if model == orientation { return }
        try await Task.sleep(for: .milliseconds(100))
      }
      throw AndroidHostClientError(message: "The emulator did not apply the requested rotation.")
    }
  }

  static func rotation(target: DeviceTarget) async throws -> ADBDisplayRotation {
    try await connect(target: target) { client, metadata in
      let model = try await read(client, metadata: metadata)
      return ADBDisplayRotation(rawValue: model) ?? .rotation0
    }
  }

  private static func read(
    _ client: GRPCClient<HTTP2ClientTransport.WrappedChannel>, metadata: Metadata
  ) async throws -> Int {
    var query = EmulatorPreview_ImageFormat()
    query.format = .rgba8888
    query.width = 16
    query.height = 16
    var screenshotOptions = options
    screenshotOptions.timeout = ScreenshotDeadline.duration
    return try await client.unary(
      request: ClientRequest(message: query, metadata: metadata),
      descriptor: method("getScreenshot"),
      serializer: EmulatorProtobufCodec<EmulatorPreview_ImageFormat>(),
      deserializer: EmulatorProtobufCodec<EmulatorPreview_Image>(),
      options: screenshotOptions
    ) { response in
      let value = try response.message.format.rotation.rotation.rawValue
      guard (0 ... 3).contains(value) else {
        throw AndroidHostClientError(message: "The emulator returned an invalid display orientation.")
      }
      return value
    }
  }

  private static func connect<Result: Sendable>(
    target: DeviceTarget,
    body: @escaping @MainActor (GRPCClient<HTTP2ClientTransport.WrappedChannel>, Metadata) async throws -> Result
  ) async throws -> Result {
    _ = try target.requireTransport(for: target.serial)
    let task = Task {
      let discovery = AndroidHostClient()
      defer { discovery.close() }
      let endpoint = try await discovery.rotationEndpoint(serial: target.serial)
      _ = try target.requireTransport(for: target.serial)
      try Task.checkCancellation()
      return try await EmulatorGRPCConnection.withDevice(target: target, endpoint: endpoint) { client, metadata in
        _ = try target.requireTransport(for: target.serial)
        try Task.checkCancellation()
        return try await body(client, metadata)
      }
    }
    let handler: UUID
    do {
      handler = try target.onInvalidation { task.cancel() }
    } catch {
      task.cancel()
      _ = await task.result
      throw error
    }
    defer { target.removeInvalidationHandler(handler) }
    return try await withTaskCancellationHandler {
      try await task.value
    } onCancel: {
      task.cancel()
    }
  }

  private static var options: CallOptions {
    var options = CallOptions.defaults
    options.timeout = .seconds(5)
    options.maxRequestMessageBytes = 4096
    options.maxResponseMessageBytes = 4096
    return options
  }

  private static func method(_ name: String) -> MethodDescriptor {
    MethodDescriptor(fullyQualifiedService: "android.emulation.control.EmulatorController", method: name)
  }
}
