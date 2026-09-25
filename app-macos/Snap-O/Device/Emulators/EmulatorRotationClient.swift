import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2TransportServices
import SwiftProtobuf

/// Uses the same virtual-device rotation model as Android Studio.
@MainActor
struct EmulatorRotationClient {
  static func rotate(deviceID: String, left: Bool) async throws {
    try await connect(deviceID: deviceID) { client, metadata in
      let current = try await read(client, metadata: metadata)
      let target = LivePreviewRotation.target(from: current, left: left)
      var value = EmulatorPreview_PhysicalModelValue()
      value.target = .rotation
      value.value.data = [0, 0, [0, 90, -180, -90][target]]
      try await client.unary(
        request: ClientRequest(message: value, metadata: metadata),
        descriptor: method("setPhysicalModel"),
        serializer: RotationProtobufCodec<EmulatorPreview_PhysicalModelValue>(),
        deserializer: RotationProtobufCodec<Google_Protobuf_Empty>(),
        options: options
      ) { _ = try $0.message }
      // The model interpolates toward its target. Serialize the next click after it settles.
      for _ in 0 ..< 30 {
        let model = try await read(client, metadata: metadata)
        if model == target { return }
        try await Task.sleep(for: .milliseconds(100))
      }
      throw EmulatorClientError(message: "The emulator did not apply the requested rotation.")
    }
  }

  static func rotation(deviceID: String) async throws -> ADBDisplayRotation {
    try await connect(deviceID: deviceID) { client, metadata in
      let model = try await read(client, metadata: metadata)
      return ADBDisplayRotation(rawValue: model) ?? .rotation0
    }
  }

  private static func read(
    _ client: GRPCClient<HTTP2ClientTransport.TransportServices>, metadata: Metadata
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
      serializer: RotationProtobufCodec<EmulatorPreview_ImageFormat>(),
      deserializer: RotationProtobufCodec<EmulatorPreview_Image>(),
      options: screenshotOptions
    ) { response in
      let value = try response.message.format.rotation.rotation.rawValue
      guard (0 ... 3).contains(value) else {
        throw EmulatorClientError(message: "The emulator returned an invalid display orientation.")
      }
      return value
    }
  }

  private static func connect<Result: Sendable>(
    deviceID: String,
    body: (GRPCClient<HTTP2ClientTransport.TransportServices>, Metadata) async throws -> Result
  ) async throws -> Result {
    let discovery = EmulatorClient()
    defer { discovery.close() }
    let endpoint = try await discovery.rotationEndpoint(serial: deviceID)
    let transport = try HTTP2ClientTransport.TransportServices(
      target: .ipv4(address: "127.0.0.1", port: endpoint.port), transportSecurity: .plaintext
    )
    var metadata = Metadata()
    if let token = endpoint.token { metadata.addString("Bearer " + token, forKey: "authorization") }
    return try await withGRPCClient(transport: transport) { client in
      try await body(client, metadata)
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

private struct RotationProtobufCodec<Message: SwiftProtobuf.Message>: MessageSerializer, MessageDeserializer {
  func serialize<Bytes: GRPCContiguousBytes>(_ message: Message) throws -> Bytes {
    try Bytes(message.serializedData())
  }

  func deserialize(_ bytes: some GRPCContiguousBytes) throws -> Message {
    try bytes.withUnsafeBytes { try Message(serializedBytes: Array($0)) }
  }
}
