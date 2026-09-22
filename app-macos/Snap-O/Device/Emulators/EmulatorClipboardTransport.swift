import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2TransportServices
import SwiftProtobuf

struct EmulatorClipboardTransport {
  typealias Client = GRPCClient<HTTP2ClientTransport.TransportServices>

  let client: Client
  let endpoint: EmulatorClipboardEndpoint

  static func connect(
    endpoint: EmulatorClipboardEndpoint,
    isolation: isolated (any Actor)? = #isolation,
    body: (Self) async throws -> Void
  ) async throws {
    let transport = try HTTP2ClientTransport.TransportServices(
      target: .ipv4(address: "127.0.0.1", port: endpoint.port), transportSecurity: .plaintext
    )
    try await withGRPCClient(transport: transport, isolation: isolation) { client in
      try await body(Self(client: client, endpoint: endpoint))
    }
  }

  func setText(_ text: String) async throws {
    // Emulator ClipData is wire-compatible with StringValue: a UTF-8 string in field 1.
    var message = Google_Protobuf_StringValue()
    message.value = text
    var options = Self.options
    options.timeout = .seconds(5)
    try await client.unary(
      request: ClientRequest(message: message, metadata: metadata),
      descriptor: Self.method("setClipboard"),
      serializer: ClipboardProtobufCodec<Google_Protobuf_StringValue>(),
      deserializer: ClipboardProtobufCodec<Google_Protobuf_Empty>(),
      options: options
    ) { response in _ = try response.message }
  }

  func getText() async throws -> String {
    var options = Self.options
    options.timeout = .seconds(5)
    return try await client.unary(
      request: ClientRequest(message: Google_Protobuf_Empty(), metadata: metadata),
      descriptor: Self.method("getClipboard"),
      serializer: ClipboardProtobufCodec<Google_Protobuf_Empty>(),
      deserializer: ClipboardProtobufCodec<Google_Protobuf_StringValue>(),
      options: options
    ) { try $0.message.value }
  }

  func receive(_ onText: @escaping @Sendable (String) async -> Void) async throws {
    try await client.serverStreaming(
      request: ClientRequest(message: Google_Protobuf_Empty(), metadata: metadata),
      descriptor: Self.method("streamClipboard"),
      serializer: ClipboardProtobufCodec<Google_Protobuf_Empty>(),
      deserializer: ClipboardProtobufCodec<Google_Protobuf_StringValue>(),
      options: Self.options
    ) { response in
      for try await message in response.messages {
        try Task.checkCancellation()
        await onText(message.value)
      }
    }
  }

  private var metadata: Metadata {
    ["authorization": .string("Bearer " + endpoint.token)]
  }

  private static var options: CallOptions {
    var options = CallOptions.defaults
    options.maxRequestMessageBytes = ClipboardSyncState.maximumTextBytes + 16
    options.maxResponseMessageBytes = ClipboardSyncState.maximumTextBytes + 16
    return options
  }

  private static func method(_ name: String) -> MethodDescriptor {
    MethodDescriptor(fullyQualifiedService: "android.emulation.control.EmulatorController", method: name)
  }
}

private struct ClipboardProtobufCodec<Message: SwiftProtobuf.Message>: MessageSerializer, MessageDeserializer {
  func serialize<Bytes: GRPCContiguousBytes>(_ message: Message) throws -> Bytes {
    try Bytes(message.serializedData())
  }

  func deserialize(_ bytes: some GRPCContiguousBytes) throws -> Message {
    try bytes.withUnsafeBytes { try Message(serializedBytes: Array($0)) }
  }
}
