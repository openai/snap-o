import Foundation

@main
struct SecurityClient {
  static func finish(_ result: String) -> Never {
    FileHandle.standardOutput.write(Data((result + "\n").utf8))
    exit(0)
  }

  static func main() {
    let name = Bundle.main.object(forInfoDictionaryKey: "TestServiceIdentifier") as! String
    let connection = NSXPCConnection(serviceName: name)
    connection.remoteObjectInterface = NSXPCInterface(with: AndroidHostServiceProtocol.self)
    connection.invalidationHandler = { finish("rejected") }
    connection.resume()
    let proxy = connection.remoteObjectProxyWithErrorHandler { @Sendable _ in finish("rejected") } as! AndroidHostServiceProtocol
    // An invalid serial returns before reading emulator files or launching any commands.
    proxy.rotationEndpoint("snapo-security-test") { _, error in
      finish(error == "The emulator's rotation connection is unavailable." ? "accepted" : "unexpected reply")
    }
    DispatchQueue.global().asyncAfter(deadline: .now() + 10) { finish("timeout") }
    dispatchMain()
  }
}
