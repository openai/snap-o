import Foundation

/// An ADB conversation. Implementations own their connection until close or socket transfer.
public protocol ADBConnection: AnyObject, Sendable {
  var ioTimeout: Duration? { get }
  var connectionTarget: DeviceTarget? { get }
  func bind(to target: DeviceTarget) throws
  func close()
  func withRequestTimeout<T>(_ timeout: Duration, _ body: () throws -> T) throws -> T
  func setIOTimeout(_ timeout: Duration?) throws
  func sendTrackDevices() throws
  func sendDevicesList() throws
  func sendTransport(to deviceID: String) throws
  func sendTransportID(_ transportID: String) throws
  func sendShell(_ command: String) throws
  func sendLocalAbstract(_ name: String) throws
  func sendHostCommand(_ command: String, expectsResponse: Bool) throws -> String?
  func sendSync() throws
  func sendSyncRequest(id: String, path: String) throws
  func readSyncData(callback: (Data) throws -> Void) throws
  func sendFile(_ file: FileHandle, remotePath: String, progress: (Int64) -> Void) throws
  func writeFully(_ data: Data) throws
  func writeLine(_ value: String) throws
  func readToEnd() throws -> Data
  func drainToEnd() throws
  func readChunk(maxLength: Int) throws -> Data?
  func readChunk<C: Clock<Duration>>(maxLength: Int, deadline: C.Instant, clock: C) throws -> Data?
  func readLengthPrefixedPayload() throws -> Data?
  func readLine(maxLength: Int?) throws -> String?
}

extension ADBConnection {
  public func withRequestTimeout<T>(_ timeout: Duration, _ body: () throws -> T) throws -> T {
    let previous = ioTimeout
    defer { try? setIOTimeout(previous) }
    try setIOTimeout(timeout)
    return try body()
  }

  func readLine() throws -> String? {
    try readLine(maxLength: nil)
  }

  func readChunk(maxLength: Int, deadline: ContinuousClock.Instant) throws -> Data? {
    try readChunk(maxLength: maxLength, deadline: deadline, clock: ContinuousClock())
  }
}

/// Only the native HTTP adapter transfers an operating-system descriptor.
protocol ADBSocketTransfer: ADBConnection {
  func takeSocketDescriptor() throws -> Int32
}
