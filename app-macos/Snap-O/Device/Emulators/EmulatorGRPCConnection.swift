import Dependencies
import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2TransportServices
import NIOTransportServices
import SwiftProtobuf

/// A native operation stays on one socket. Preview recovery owns any reconnection.
enum EmulatorGRPCConnection {
  static func open(port: Int, connected: @escaping @Sendable (Int) -> Void = { _ in }) async throws -> HTTP2ClientTransport.WrappedChannel {
    try Task.checkCancellation()
    let config = HTTP2ClientTransport.WrappedChannel.Config.defaults {
      // Wrapped channels cannot infer the authority required by the emulator's HTTP/2 server.
      $0.http2.authority = "127.0.0.1:\(port)"
    }
    let transport = try await HTTP2ClientTransport.WrappedChannel.wrapping(config: config) { configure in
      let channel = try await NIOTSConnectionBootstrap(group: .singletonNIOTSEventLoopGroup)
        .connectTimeout(.seconds(5))
        .channelOption(NIOTSChannelOptions.waitForActivity, value: false)
        .connect(host: "127.0.0.1", port: port, channelInitializer: configure)
      if let localPort = channel.channel.localAddress?.port { connected(localPort) }
      return channel
    }
    if Task.isCancelled {
      transport.beginGracefulShutdown()
      try? await transport.connect()
      throw CancellationError()
    }
    return transport
  }

  /// The native log stream must observe a fresh marker written through the selected ADB transport.
  static func verify(
    client: GRPCClient<HTTP2ClientTransport.WrappedChannel>,
    metadata: Metadata,
    writeMarker: @escaping @Sendable (String) async throws -> Void
  ) async throws {
    @Dependency(\.continuousClock)
    var clock
    let marker = "snapo-connection-" + UUID().uuidString.lowercased()
    var options = CallOptions.defaults
    options.timeout = .seconds(5)
    options.maxResponseMessageBytes = 64 * 1024
    let readOptions = options
    do {
      try await withThrowingTaskGroup(of: Void.self) { group in
        defer { group.cancelAll() }
        group.addTask {
          // LogMessage's text contents is field 1, matching StringValue. An empty request selects text output.
          try await client.serverStreaming(
            request: ClientRequest(message: Google_Protobuf_Empty(), metadata: metadata),
            descriptor: MethodDescriptor(fullyQualifiedService: "android.emulation.control.EmulatorController", method: "streamLogcat"),
            serializer: EmulatorProtobufCodec<Google_Protobuf_Empty>(),
            deserializer: EmulatorProtobufCodec<Google_Protobuf_StringValue>(), options: readOptions
          ) { response in
            for try await message in response.messages where message.value.contains(marker) {
              return
            }
            throw RPCError(code: .failedPrecondition, message: "The emulator connection could not be verified.")
          }
        }
        group.addTask { [clock] in
          while true {
            try Task.checkCancellation()
            try await writeMarker(marker)
            // Registration can lag the first write; retry without waiting for Android display services.
            try await clock.sleep(for: .milliseconds(250))
          }
        }
        _ = try await group.next()
      }
    } catch let error as RPCError where error.code == .deadlineExceeded {
      throw EmulatorVerificationError()
    }
  }
}

struct EmulatorVerificationError: LocalizedError {
  var errorDescription: String? {
    "The emulator's connection check timed out. Restart the emulator, then reconnect."
  }
}

struct EmulatorProtobufCodec<Message: SwiftProtobuf.Message>: MessageSerializer, MessageDeserializer {
  func serialize<Bytes: GRPCContiguousBytes>(_ message: Message) throws -> Bytes {
    try Bytes(message.serializedData())
  }

  func deserialize(_ bytes: some GRPCContiguousBytes) throws -> Message {
    try bytes.withUnsafeBytes { buffer in
      guard let baseAddress = buffer.baseAddress else { return try Message(serializedBytes: Data()) }
      // Borrow transport storage only during decoding; protobuf owns the decoded fields.
      let data = Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: baseAddress), count: buffer.count, deallocator: .none)
      return try Message(serializedBytes: data)
    }
  }
}
