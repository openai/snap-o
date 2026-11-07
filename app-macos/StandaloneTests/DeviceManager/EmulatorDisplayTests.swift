import Foundation

private final class DisplayProvider: NSObject, EmulatorDisplayProvider, @unchecked Sendable {
  let value: String?
  let error: String?
  init(value: String?, error: String?) {
    self.value = value
    self.error = error
  }

  func readDisplay(reply: @escaping @Sendable (String?, String?) -> Void) {
    reply(value, error)
  }
}

private final class DisplayHost: NSObject {
  @objc
  func controls(
    _ serial: String, native: Data, display: any EmulatorDisplayProvider, reply: @escaping @Sendable (Data?, String?) -> Void
  ) {
    DispatchQueue.global().async {
      do { try reply(Data(EmulatorDisplayReader(provider: display).read().utf8), nil) } catch { reply(nil, error.localizedDescription) }
    }
  }
}

private final class DisplayListener: NSObject, NSXPCListenerDelegate {
  let host = DisplayHost()
  func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
    connection.exportedInterface = AndroidHostInterface.make()
    connection.exportedObject = host
    connection.resume()
    return true
  }
}

private final class DisplayResponse: @unchecked Sendable {
  let ready = DispatchSemaphore(value: 0)
  private let lock = NSLock()
  private var output: (Data?, String?) = (nil, nil)
  var value: (Data?, String?) {
    lock.withLock { output }
  }

  func finish(_ data: Data?, _ error: String?) {
    lock.withLock { output = (data, error) }
    ready.signal()
  }
}

func runDisplayBridgeTests() throws {
  for (value, error) in [("Physical size: 1080x2400", nil), (nil, "The device connection changed.")] as [(String?, String?)] {
    // An anonymous connection exercises proxy encoding in this process, without launching an app or helper.
    let listener = NSXPCListener.anonymous()
    let delegate = DisplayListener()
    listener.delegate = delegate
    listener.resume()
    let connection = NSXPCConnection(listenerEndpoint: listener.endpoint)
    connection.remoteObjectInterface = AndroidHostInterface.make()
    connection.resume()
    let response = DisplayResponse()
    let remote = connection.remoteObjectProxyWithErrorHandler { response.finish(nil, $0.localizedDescription) }
    guard let remote = remote as? AndroidHostServiceProtocol else { fatalError("Missing test proxy") }
    remote.controls("emulator-5554", native: Data(), display: DisplayProvider(value: value, error: error)) { response.finish($0, $1) }
    response.ready.wait()
    let result = response.value
    connection.invalidate()
    listener.invalidate()
    withExtendedLifetime(delegate) {}
    try expect(result.0.flatMap { String(data: $0, encoding: .utf8) } == value, "Round-trip proxied display data")
    try expect(result.1 == error, "Round-trip proxied display failures")
  }
}
