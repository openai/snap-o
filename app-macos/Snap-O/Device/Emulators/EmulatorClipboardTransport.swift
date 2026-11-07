import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2TransportServices
import SwiftProtobuf

struct EmulatorClipboardTransport: ClipboardTransport {
  private let client: GRPCClient<HTTP2ClientTransport.WrappedChannel>
  private let authentication: EmulatorClipboardAuthentication

  static func connect(
    target: DeviceTarget,
    endpoint: EmulatorGRPCEndpoint,
    authentication: EmulatorClipboardAuthentication,
    isolation: isolated (any Actor)? = #isolation,
    body: (Self) async throws -> Void
  ) async throws {
    try await EmulatorGRPCConnection.withDevice(target: target, endpoint: endpoint, isolation: isolation) { client, _ in
      try await body(Self(client: client, authentication: authentication))
    }
  }

  func setText(_ text: String) async throws {
    // Emulator ClipData is wire-compatible with StringValue: a UTF-8 string in field 1.
    var message = Google_Protobuf_StringValue()
    message.value = text
    try await client.unary(
      request: ClientRequest(message: message, metadata: metadata()),
      descriptor: Self.method("setClipboard"),
      serializer: EmulatorProtobufCodec<Google_Protobuf_StringValue>(),
      deserializer: EmulatorProtobufCodec<Google_Protobuf_Empty>(),
      options: Self.options(timeout: .seconds(5))
    ) { response in _ = try response.message }
  }

  func getText() async throws -> String {
    try await client.unary(
      request: ClientRequest(message: Google_Protobuf_Empty(), metadata: metadata()),
      descriptor: Self.method("getClipboard"),
      serializer: EmulatorProtobufCodec<Google_Protobuf_Empty>(),
      deserializer: EmulatorProtobufCodec<Google_Protobuf_StringValue>(),
      options: Self.options(timeout: .seconds(5))
    ) { try $0.message.value }
  }

  func receive(_ onText: @escaping @Sendable (String) async -> Void) async throws {
    try await client.serverStreaming(
      request: ClientRequest(message: Google_Protobuf_Empty(), metadata: metadata()),
      descriptor: Self.method("streamClipboard"),
      serializer: EmulatorProtobufCodec<Google_Protobuf_Empty>(),
      deserializer: EmulatorProtobufCodec<Google_Protobuf_StringValue>(),
      options: Self.options()
    ) { response in
      for try await message in response.messages {
        try Task.checkCancellation()
        await onText(message.value)
      }
    }
  }

  private func metadata() async throws -> Metadata {
    try await ["authorization": .string("Bearer " + authentication.token())]
  }

  private static func options(timeout: Duration? = nil) -> CallOptions {
    var options = CallOptions.defaults
    options.timeout = timeout
    options.maxRequestMessageBytes = ClipboardSyncState.maximumTextBytes + 16
    options.maxResponseMessageBytes = ClipboardSyncState.maximumTextBytes + 16
    return options
  }

  private static func method(_ name: String) -> MethodDescriptor {
    MethodDescriptor(fullyQualifiedService: "android.emulation.control.EmulatorController", method: name)
  }
}
