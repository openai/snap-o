import Foundation

@MainActor
struct AndroidHostControlTests {
  private static let native = EmulatorNativeConnection(processID: 1, grpcPort: 8554, clientPort: 12345)

  static func run() async throws {
    try await socketHandoffSurvivesSenderClose()
    try await joinsHelperReply(cancelRequest: true)
    try await joinsHelperReply(cancelRequest: false)
    try await ownerJoinsHelperBeforeClosing()
    print("Android host control cancellation tests passed")
  }

  private static func socketHandoffSurvivesSenderClose() async throws {
    let listener = NSXPCListener.anonymous()
    let host = SocketTestHost()
    let delegate = ControlTestListener(host: host)
    listener.delegate = delegate
    listener.resume()
    defer { listener.invalidate()
      withExtendedLifetime(delegate) {}
    }
    let client = AndroidHostClient { NSXPCConnection(listenerEndpoint: listener.endpoint) }
    defer { client.close() }
    let factory = client.tunnelSocketFactory(id: "owned")
    try await Task.detached {
      let handle = try factory()
      let connection = try ADBSocketConnection(fileHandle: handle)
      defer { connection.close() }
      try connection.setIOTimeout(.seconds(2))
      let bytes = try connection.readChunk(maxLength: 1)
      precondition(bytes == Data([42]))
      try connection.writeFully(Data([43]))
    }.value
    let rejected = client.tunnelSocketFactory(id: "another-client")
    let failed = await Task.detached {
      do {
        let handle = try rejected()
        try? handle.close()
        return false
      } catch { return true }
    }.value
    precondition(failed)
    print("XPC socket handoff and rejected tunnel tests passed")
  }

  private static func ownerJoinsHelperBeforeClosing() async throws {
    let listener = NSXPCListener.anonymous()
    let host = ControlTestHost()
    let delegate = ControlTestListener(host: host)
    listener.delegate = delegate
    listener.resume()
    defer { listener.invalidate()
      withExtendedLifetime(delegate) {}
    }
    let target = DeviceTarget(serial: "emulator-5554", transportID: "42")
    let read = TestSuspension()
    let cancelled = TestSignal()
    let client = AndroidHostClient(connectionFactory: {
      NSXPCConnection(listenerEndpoint: listener.endpoint)
    }, displayReader: { actual in
      precondition(actual == target)
      return try await withTaskCancellationHandler {
        try await read.wait()
        return "Physical size: 1080x2400"
      } onCancel: { cancelled.signal() }
    })
    let closes = TestValue(0)
    let changed = TestValue(false)
    let owner = EmulatorControlsController(target: target, load: { _ in
      EmulatorControls(avdPath: "/Synthetic.avd", commands: "posture", properties: [:])
    }, apply: { target, path, action in
      try await client.control(target: target, native: native, avdPath: path, action: action)
    }, close: {
      closes.value += 1
      client.close()
    })
    owner.appear(viewID: UUID())
    try await waitForState { owner.controls != nil }
    owner.perform(.foldable) { changed.value = true }
    await read.waitUntilStarted()
    let revision = cancelled.revision
    let shutdown = owner.beginShutdown()
    let completed = TestValue(false)
    let waiter = Task { await shutdown.value
      completed.value = true
    }
    try await cancelled.wait(after: revision)
    precondition(closes.value == 0 && !completed.value)
    read.resume()
    try await host.waitForDisplayReply()
    precondition(host.displayFailed && closes.value == 0 && !completed.value)
    host.finish()
    await waiter.value
    await owner.shutdown()
    precondition(closes.value == 1 && read.wasCancelled && !changed.value)
    precondition(owner.controls == nil && owner.failure == nil)
  }

  private static func joinsHelperReply(cancelRequest: Bool) async throws {
    let listener = NSXPCListener.anonymous()
    let host = ControlTestHost()
    let delegate = ControlTestListener(host: host)
    listener.delegate = delegate
    listener.resume()
    defer { listener.invalidate()
      withExtendedLifetime(delegate) {}
    }
    let target = DeviceTarget(serial: "emulator-5554", transportID: "42")
    let read = TestSuspension()
    let cancelled = TestSignal()
    let client = AndroidHostClient(connectionFactory: {
      NSXPCConnection(listenerEndpoint: listener.endpoint)
    }, displayReader: { actual in
      precondition(actual == target)
      return try await withTaskCancellationHandler {
        try await read.wait()
        return "Physical size: 1080x2400"
      } onCancel: { cancelled.signal() }
    })
    let completed = TestValue(false)
    let operation = Task { @MainActor in
      defer { completed.value = true }
      do {
        try await client.control(target: target, native: native, avdPath: "/Synthetic.avd", action: .foldable)
        preconditionFailure("Cancelled or replaced control must not succeed")
      } catch {}
    }
    await read.waitUntilStarted()
    let revision = cancelled.revision
    if cancelRequest { operation.cancel() } else { target.invalidate() }
    try await cancelled.wait(after: revision)
    precondition(!completed.value, "Control must join its helper reply")
    read.resume()
    try await host.waitForDisplayReply()
    precondition(host.displayFailed && !completed.value)
    host.finish()
    await operation.value
    precondition(completed.value && read.wasCancelled)
    client.close()
  }
}

private final class ControlTestListener: NSObject, NSXPCListenerDelegate {
  let host: NSObject
  init(host: NSObject) {
    self.host = host
  }

  func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
    connection.exportedInterface = AndroidHostInterface.make()
    connection.exportedObject = host
    connection.resume()
    return true
  }
}

private final class ControlTestHost: NSObject, @unchecked Sendable {
  private let lock = NSLock()
  private let replied = TestSignal()
  private var reply: (@Sendable (Data?, String?) -> Void)?
  private var received = false
  private var failed = false
  var displayFailed: Bool {
    lock.withLock { failed }
  }

  @objc
  func control(
    _ serial: String, request: Data, display: any EmulatorDisplayProvider,
    reply: @escaping @Sendable (Data?, String?) -> Void
  ) {
    lock.withLock { self.reply = reply }
    display.readDisplay { [self] value, error in
      lock.withLock { received = true
        failed = value == nil && error != nil
      }
      replied.signal()
    }
  }

  func waitForDisplayReply() async throws {
    while true {
      let revision = replied.revision
      if lock.withLock({ received }) { return }
      try await replied.wait(after: revision)
    }
  }

  func finish() {
    let callback = lock.withLock { let callback = reply
      reply = nil
      return callback
    }
    callback?(Data(), nil)
  }
}

private final class SocketTestHost: NSObject, @unchecked Sendable {
  @objc
  func connectADBTunnel(_ id: String, reply: @escaping @Sendable (FileHandle?, String?) -> Void) {
    guard id == "owned" else { reply(nil, "Unknown tunnel")
      return
    }
    var descriptors = [Int32](repeating: -1, count: 2)
    guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else { reply(nil, "socketpair failed")
      return
    }
    let sent = FileHandle(fileDescriptor: descriptors[0], closeOnDealloc: true)
    let peer = FileHandle(fileDescriptor: descriptors[1], closeOnDealloc: true)
    defer { try? sent.close() }
    do {
      try peer.write(contentsOf: Data([42]))
      reply(sent, nil)
      DispatchQueue.global().async {
        defer { try? peer.close() }
        let bytes = try? peer.read(upToCount: 1)
        precondition(bytes == Data([43]))
      }
    } catch { try? peer.close()
      reply(nil, error.localizedDescription)
    }
  }
}
