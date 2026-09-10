import Foundation

public struct ADBForwardHandle: Sendable {
  public let port: UInt16
}

public final class ADBClient: @unchecked Sendable {
  private let lock = NSLock()
  private var forwards = 0
  private var propertiesRecovered = false
  private var socketDevices: [String] = []
  private let trackedDevices = AsyncThrowingStream<String, Error>.makeStream()
  public init() {}
  public var forwardCount: Int {
    lock.withLock { forwards }
  }

  public func forwardLocalAbstract(deviceID: String, abstractSocket: String) async throws -> ADBForwardHandle {
    lock.withLock { forwards += 1 }
    if deviceID == "forward-failure" { throw ADBError.requestTimedOut("Test timeout") }
    return ADBForwardHandle(port: deviceID == "frozen" ? 12345 : 12346)
  }

  public var scannedDeviceIDs: [String] {
    lock.withLock { socketDevices }
  }

  public func recoverProperties() {
    lock.withLock { propertiesRecovered = true }
  }

  public func emitDevices(_ payload: String) {
    trackedDevices.continuation.yield(payload)
  }

  public func trackDevices() async throws -> (handle: TrackDevicesHandle, stream: AsyncThrowingStream<String, Error>) {
    (TrackDevicesHandle { self.trackedDevices.continuation.finish() }, trackedDevices.stream)
  }

  public func getProperties(deviceID: String, prefix: String?) async throws -> [String: String] {
    if deviceID == "stalled", !lock.withLock({ propertiesRecovered }) { throw ADBError.requestTimedOut("Test timeout") }
    return ["ro.product.model": deviceID, "ro.build.version.release": "Test"]
  }

  public func openApp(deviceID: String, packageName: String, androidUserID: Int) async throws {}

  public func removeForward(_ handle: ADBForwardHandle) async {}
  public func listUnixSockets(deviceID: String) async throws -> String {
    lock.withLock { socketDevices.append(deviceID) }
    return "1: 0 @snapo_network_42\n2: 0 @snapo_tweaks_42"
  }

  public func runDiscoveryShellString(deviceID: String, command: String) async throws -> String {
    command.contains("cmdline") ? "com.example.demo" : "Uid: 10000"
  }
}

public actor NetworkSession {
  public static let state = State()
  private let recordsStream = AsyncStream<NetworkServerRecord>.makeStream()

  public final class State: @unchecked Sendable {
    private let lock = NSLock()
    private var attempts = 0
    private var frozen = true
    private var frozenSession: NetworkSession?
    public var count: Int {
      lock.withLock { attempts }
    }

    public func unfreeze() {
      lock.withLock { frozen = false }
    }

    public func disconnectFrozen() async {
      let session = lock.withLock { frozenSession }
      await session?.close()
    }

    func record(_ session: NetworkSession, device: String) {
      if device == "frozen" { lock.withLock { frozenSession = session } }
    }

    func shouldFail(_ device: String) -> Bool {
      lock.withLock {
        attempts += 1
        return device == "frozen" && frozen
      }
    }
  }

  public static func connect(
    to reference: NetworkServerReference, using adb: ADBClient, defaultCommandTimeout: Duration
  ) async throws -> NetworkSession {
    if state.shouldFail(reference.deviceId) { throw ADBError.requestTimedOut("Test timeout") }
    let session = NetworkSession()
    state.record(session, device: reference.deviceId)
    return session
  }

  public func records() -> AsyncStream<NetworkServerRecord> {
    recordsStream.stream
  }

  public func close() {
    recordsStream.continuation.finish()
  }

  public func send(method: String) async throws {}
  public func command(method: String, params: [String: JSONValue], timeout: Duration) async throws -> NetworkCDPMessage {
    NetworkCDPMessage(id: 1)
  }
}

public struct TrackDevicesHandle: Sendable {
  let onCancel: @Sendable () -> Void
  public func cancel() {
    onCancel()
  }
}
