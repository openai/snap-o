import Clocks
import Dependencies
import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2TransportServices
import NIOCore
import NIOHTTP2
import SwiftProtobuf
import Synchronization

@main
struct EmulatorGRPCConnectionTests {
  static let echo = MethodDescriptor(fullyQualifiedService: "Synthetic", method: "Echo")

  static func main() async throws {
    let peers = Peers()
    let transport = HTTP2ServerTransport.TransportServices(
      address: .ipv4(host: "127.0.0.1", port: 0), transportSecurity: .plaintext,
      config: .defaults { config in
        config.channelDebuggingCallbacks.onAcceptTCPConnection = { channel in
          peers.add(channel)
          return channel.eventLoop.makeSucceededVoidFuture()
        }
        config.channelDebuggingCallbacks.onAcceptHTTP2Stream = { channel in
          channel.pipeline.addHandler(RequireAuthority(), position: .first)
        }
      }
    )
    let server = GRPCServer(transport: transport, services: [Echo()])
    try await withThrowingDiscardingTaskGroup { group in
      group.addTask { try await server.serve() }
      defer { server.beginGracefulShutdown() }
      let address = try await transport.listeningAddress
      guard let port = address.ipv4?.port else { preconditionFailure("Expected a loopback listener") }
      let clientPort = Mutex(0)
      let connection = try await EmulatorGRPCConnection.open(port: port) { port in clientPort.withLock { $0 = port } }
      try await withGRPCClient(transport: connection) { client in
        for text in ["first", "second"] {
          let reply = try await request(text, client: client)
          precondition(reply == text)
        }
        precondition(peers.count == 1, "RPCs must share the original native connection")
        precondition(clientPort.withLock { $0 } == peers.first.remoteAddress?.port, "Report the actual connected socket port")
        try await peers.first.close().get()
        do {
          _ = try await request("after disconnect", client: client)
          preconditionFailure("A disconnected operation must not reconnect to the listener")
        } catch let error as RPCError {
          precondition(error.code == .unavailable)
        } catch let error as RuntimeError {
          // The client may finish stopping before the request reaches the closed transport.
          precondition(error.code == .clientIsStopped)
        }
        precondition(peers.count == 1, "The listener stayed available but must not receive a replacement connection")
      }
      let final = try await EmulatorGRPCConnection.open(port: port)
      try await withGRPCClient(transport: final) { client in
        let reply = try await request("new operation", client: client)
        precondition(reply == "new operation")
      }
      precondition(peers.count == 2, "Only the two explicitly opened connections may reach the listener")
      try await peers.last.closeFuture.get()
    }
    for mode in [ProofMode.matches, .mismatch, .retry, .cancel, .timeout] {
      try await identity(mode)
    }
    print("Emulator gRPC connection and identity tests passed")
  }

  enum ProofMode { case matches, mismatch, retry, cancel, timeout }

  @MainActor
  static func identity(_ mode: ProofMode) async throws {
    let feed = LogFeed()
    let transport = HTTP2ServerTransport.TransportServices(
      address: .ipv4(host: "127.0.0.1", port: 0), transportSecurity: .plaintext
    )
    let server = GRPCServer(transport: transport, services: [feed])
    let clock = TestClock()
    try await withDependencies { $0.continuousClock = clock } operation: {
      try await withThrowingDiscardingTaskGroup { group in
        group.addTask { try await server.serve() }
        defer { server.beginGracefulShutdown() }
        let address = try await transport.listeningAddress
        guard let port = address.ipv4?.port else { preconditionFailure("Expected loopback listener") }
        let connection = try await EmulatorGRPCConnection.open(port: port)
        try await withGRPCClient(transport: connection) { client in
          let writes = AsyncStream<String>.makeStream()
          let gate = TestGate()
          let finished = TestValue(false)
          let proof = Task {
            defer { finished.value = true }
            try await EmulatorGRPCConnection.verify(client: client, metadata: [:]) { marker in
              writes.continuation.yield(marker)
              if mode == .matches { feed.emit("unrelated log line")
                feed.emit(marker)
              }
              if mode == .mismatch { feed.emit("snapo-connection-wrong-device")
                feed.finish()
              }
              if mode == .cancel { await gate.wait() }
              if mode == .timeout { feed.fail(RPCError(code: .deadlineExceeded, message: "Synthetic native timeout")) }
            }
          }
          var iterator = writes.stream.makeAsyncIterator()
          let first = await iterator.next()
          precondition(first?.hasPrefix("snapo-connection-") == true)
          if mode == .retry {
            await clock.advance(by: .milliseconds(250))
            let second = await iterator.next()
            precondition(first == second, "A delayed log subscription must retry the same challenge")
            guard let second else { preconditionFailure("Expected a retried marker") }
            feed.emit(second)
          }
          if mode == .cancel {
            await waitForActorTestState { await gate.waitCount == 1 }
            proof.cancel()
            precondition(!finished.value, "Cancellation must join the pending ADB marker write")
            await gate.open()
          }
          let result = await proof.result
          switch (mode, result) {
          case (.matches, .success), (.retry, .success): break
          case (.mismatch, .failure(let error)):
            precondition((error as? RPCError)?.code == .failedPrecondition)
          case (.timeout, .failure(let error)):
            precondition(error is EmulatorVerificationError, "Native verification timeout must have a useful recovery message")
          case (.cancel, .failure): break
          default: preconditionFailure("Unexpected identity result: \(result)")
          }
          writes.continuation.finish()
          feed.finish()
          try await clock.checkSuspension()
        }
      }
    }
  }

  struct LogFeed: RegistrableRPCService {
    private let messages = AsyncThrowingStream<String, any Error>.makeStream()
    func emit(_ text: String) {
      messages.continuation.yield(text)
    }

    func finish() {
      messages.continuation.finish()
    }

    func fail(_ error: any Error) {
      messages.continuation.finish(throwing: error)
    }

    func registerMethods(with router: inout RPCRouter<some ServerTransport>) {
      router.registerHandler(
        forMethod: MethodDescriptor(fullyQualifiedService: "android.emulation.control.EmulatorController", method: "streamLogcat"),
        deserializer: EmulatorProtobufCodec<Google_Protobuf_Empty>(),
        serializer: EmulatorProtobufCodec<Google_Protobuf_StringValue>()
      ) { _, _ in
        StreamingServerResponse { writer in
          for try await text in messages.stream {
            var value = Google_Protobuf_StringValue()
            value.value = text
            try await writer.write(value)
          }
          return [:]
        }
      }
    }
  }

  static func request(_ text: String, client: GRPCClient<HTTP2ClientTransport.WrappedChannel>) async throws -> String {
    var options = CallOptions.defaults
    options.timeout = .seconds(5)
    options.waitForReady = true
    return try await client.unary(
      request: ClientRequest(message: text), descriptor: echo,
      serializer: TextCodec(), deserializer: TextCodec(), options: options
    ) { try $0.message }
  }

  struct Echo: RegistrableRPCService {
    func registerMethods(with router: inout RPCRouter<some ServerTransport>) {
      router.registerHandler(forMethod: echo, deserializer: TextCodec(), serializer: TextCodec()) { request, _ in
        StreamingServerResponse { writer in
          for try await message in request.messages {
            try await writer.write(message)
          }
          return [:]
        }
      }
    }
  }

  struct TextCodec: MessageSerializer, MessageDeserializer {
    func serialize<Bytes: GRPCContiguousBytes>(_ message: String) throws -> Bytes {
      Bytes(Array(message.utf8))
    }

    func deserialize(_ bytes: some GRPCContiguousBytes) throws -> String {
      try bytes.withUnsafeBytes {
        guard let text = String(bytes: $0, encoding: .utf8) else {
          throw RPCError(code: .invalidArgument, message: "Invalid UTF-8 test message")
        }
        return text
      }
    }
  }

  final class RequireAuthority: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTP2Frame.FramePayload

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
      if case .headers(let frame) = unwrapInboundIn(data) {
        let port = context.channel.localAddress!.port!
        precondition(frame.headers[":authority"] == ["127.0.0.1:\(port)"], "Native RPCs need an HTTP/2 authority")
      }
      context.fireChannelRead(data)
    }
  }

  final class Peers: @unchecked Sendable {
    private let lock = NSLock()
    private var channels: [any Channel] = []
    var count: Int {
      lock.withLock { channels.count }
    }

    var first: any Channel {
      lock.withLock { channels[0] }
    }

    var last: any Channel {
      lock.withLock { channels[channels.count - 1] }
    }

    func add(_ channel: any Channel) {
      lock.withLock { channels.append(channel) }
    }
  }
}
