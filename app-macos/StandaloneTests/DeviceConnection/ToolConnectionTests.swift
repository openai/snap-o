import Darwin
import Foundation

@main
struct ToolConnectionTests {
  static func main() async throws {
    var sockets: [Int32] = [0, 0]
    guard socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets) == 0 else { throw POSIXError(.EIO) }
    let connection = ADBSocketConnection(connectedSocket: sockets[0])
    let peer = ADBSocketConnection(connectedSocket: sockets[1])
    defer { connection.close(); peer.close() }
    let target = DeviceTarget(serial: "synthetic", transportID: "1")
    try connection.bind(to: target)
    let input = try ToolHTTPRequestInput(request: URLRequest(url: ToolURL.api))
    let operation = ToolHTTPRequestOperation(input: input) { connection }
    let running = Task {
      try await operation.run(onResponse: { _ in }, onData: { _ in })
    }
    // The first HTTP request proves that NIO has adopted the descriptor.
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      DispatchQueue.global().async {
        continuation.resume(with: Result {
          var request = Data()
          while request.range(of: Data("\r\n\r\n".utf8)) == nil {
            guard let chunk = try peer.readChunk(maxLength: 4096) else {
              throw ADBError.protocolFailure("Tool socket closed before its request")
            }
            request.append(chunk)
          }
        })
      }
    }
    target.invalidate()
    do {
      try await running.value
      preconditionFailure("Invalidation must interrupt the HTTP response")
    } catch {}
    let end = try peer.readChunk(maxLength: 1)
    precondition(end == nil, "The transferred descriptor must close with its connection")
    print("Connection invalidation closes NIO-owned tool sockets")
  }
}
