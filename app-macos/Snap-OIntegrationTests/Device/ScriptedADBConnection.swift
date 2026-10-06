import Foundation
#if !SNAPO_STANDALONE_TESTS
@testable import Snap_O
#endif

/// Records ADB commands and supplies replies without a socket or a system deadline.
final class ScriptedADBConnection: ADBConnection, @unchecked Sendable {
  enum Read: @unchecked Sendable {
    case data(Data), end, failure(any Error), waitForClose
  }

  private let condition = NSCondition()
  private let changed = TestSignal()
  private var reads: [Read]
  private var commandLog: [String] = []
  private var output = Data()
  private var closed = false
  private var blocked = false
  private var target: DeviceTarget?
  private var invalidation: UUID?
  private var timeout: Duration?
  private var timeoutLog: [Duration?] = []
  let commandFailure: String?
  let blockedCommand: String?
  var respond: (@Sendable (String) throws -> String?)?
  let commandReply: String?

  init(reads: [Read] = [.end], commandFailure: String? = nil, blockedCommand: String? = nil, commandReply: String? = nil) {
    self.reads = reads
    self.commandFailure = commandFailure
    self.blockedCommand = blockedCommand
    self.commandReply = commandReply
  }

  var commands: [String] {
    condition.withLock { commandLog }
  }

  var written: Data {
    condition.withLock { output }
  }

  var isClosed: Bool {
    condition.withLock { closed }
  }

  var ioTimeout: Duration? {
    condition.withLock { timeout }
  }

  var timeouts: [Duration?] {
    condition.withLock { timeoutLog }
  }

  var connectionTarget: DeviceTarget? {
    condition.withLock { target }
  }

  func bind(to target: DeviceTarget) throws {
    _ = try target.requireTransport(for: target.serial)
    condition.withLock { self.target = target }
    let handler = try target.onInvalidation { [weak self] in self?.close() }
    condition.withLock { invalidation = handler }
  }

  func close() {
    let registration = condition.withLock {
      closed = true
      condition.broadcast()
      let registration = (target, invalidation)
      invalidation = nil
      return registration
    }
    if let id = registration.1 { registration.0?.removeInvalidationHandler(id) }
    changed.signal()
  }

  func waitUntilBlocked() async throws {
    while true {
      let revision = changed.revision
      if condition.withLock({ blocked }) { return }
      try await changed.wait(after: revision)
    }
  }

  func blockUntilClosed() throws {
    condition.lock()
    defer { condition.unlock() }
    blocked = true
    changed.signal()
    while !closed {
      condition.wait()
    }
    throw CancellationError()
  }

  func setIOTimeout(_ value: Duration?) throws {
    condition.withLock { timeout = value
      timeoutLog.append(value)
    }
  }

  func sendHostCommand(_ command: String, expectsResponse: Bool) throws -> String? {
    condition.withLock { commandLog.append(command) }
    if command == blockedCommand { try blockUntilClosed() }
    if command == commandFailure { throw ADBError.requestTimedOut("Synthetic timeout") }
    return try respond?(command) ?? commandReply
  }

  func sendTrackDevices() throws {
    _ = try sendHostCommand("host:track-devices-l", expectsResponse: false)
  }

  func sendDevicesList() throws {
    _ = try sendHostCommand("host:devices-l", expectsResponse: false)
  }

  func sendTransportID(_ id: String) throws {
    _ = try sendHostCommand("host:transport-id:" + id, expectsResponse: false)
  }

  func sendTransport(to deviceID: String) throws {
    if let target = connectionTarget {
      try target.selectTransport(for: deviceID) { try sendTransportID($0) }
    } else { _ = try sendHostCommand("host:transport:" + deviceID, expectsResponse: false) }
  }

  func sendShell(_ command: String) throws {
    _ = try sendHostCommand("shell:" + command, expectsResponse: false)
  }

  func sendLocalAbstract(_ name: String) throws {
    _ = try sendHostCommand("localabstract:" + name, expectsResponse: false)
  }

  func sendSync() throws {
    _ = try sendHostCommand("sync:", expectsResponse: false)
  }

  func writeFully(_ data: Data) throws {
    condition.withLock { output.append(data) }
  }

  func writeLine(_ value: String) throws {
    try writeFully(Data((value + "\n").utf8))
  }

  func enqueue(_ values: [Read]) {
    condition.withLock { reads.append(contentsOf: values) }
  }

  func readChunk(maxLength: Int) throws -> Data? {
    let next: Read = condition.withLock {
      guard !closed else { return .failure(CancellationError()) }
      guard !reads.isEmpty else { return .failure(UnexpectedRead()) }
      return reads.removeFirst()
    }
    switch next {
    case .data(let data):
      let result = Data(data.prefix(maxLength))
      if data.count > maxLength { condition.withLock { reads.insert(.data(Data(data.dropFirst(maxLength))), at: 0) } }
      return result
    case .end: return nil
    case .failure(let error): throw error
    case .waitForClose: try blockUntilClosed()
      return nil
    }
  }

  func readChunk<C: Clock<Duration>>(maxLength: Int, deadline: C.Instant, clock: C) throws -> Data? {
    precondition(clock.now < deadline, "Scripted read started after its deadline")
    return try readChunk(maxLength: maxLength)
  }

  func readLengthPrefixedPayload() throws -> Data? {
    try readChunk(maxLength: Int.max)
  }

  func readLine(maxLength: Int?) throws -> String? {
    try readChunk(maxLength: maxLength ?? Int.max).map { String(decoding: $0, as: UTF8.self) }
  }

  func readToEnd() throws -> Data {
    var result = Data()
    while let chunk = try readChunk(maxLength: 65536) {
      result.append(chunk)
    }
    return result
  }

  func drainToEnd() throws {
    _ = try readToEnd()
  }

  func sendSyncRequest(id: String, path: String) throws {
    throw UnexpectedRead()
  }

  func readSyncData(callback: (Data) throws -> Void) throws {
    throw UnexpectedRead()
  }

  func sendFile(_ file: FileHandle, remotePath: String, progress: (Int64) -> Void) throws {
    throw UnexpectedRead()
  }

  private struct UnexpectedRead: Error {}
}
