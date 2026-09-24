import Foundation

public struct ADBClient: Sendable {
  private let connectionFactory: @Sendable () throws -> ADBSocketConnection
  private let discoveryTimeout: Duration
  private var requestTimeout: Duration?
  private let recordingTimeouts = RecordingTimeouts()

  struct RecordingTimeouts {
    var command: Duration = .seconds(3)
    var finalization: Duration = .seconds(5)
    var download: Duration = .seconds(120)
    var downloadIdle: Duration = .seconds(5)
  }

  func withTimeout(_ timeout: Duration?) -> ADBClient {
    var client = self
    client.requestTimeout = timeout
    return client
  }

  // MARK: - Public entry points

  public init() {
    connectionFactory = { try ADBSocketConnection() }
    discoveryTimeout = .seconds(2)
  }

  init(
    discoveryTimeout: Duration,
    connectionFactory: @escaping @Sendable () throws -> ADBSocketConnection
  ) {
    self.discoveryTimeout = discoveryTimeout
    self.connectionFactory = connectionFactory
  }

  public func screencapPNG(deviceID: String) async throws -> Data {
    try await runShellData(deviceID: deviceID, command: "screencap -p 2>/dev/null")
  }

  public func startScreenrecord(
    deviceID: String,
    bitRateMbps: Int = 8,
    timeLimitSeconds: Int = 60 * 60 * 3,
    bugReport: Bool = false
  ) async throws -> RecordingSession {
    let sizeHint = try? await withTimeout(recordingTimeouts.command).displaySize(deviceID: deviceID)
    let remote = "/data/local/tmp/snapo_recording_\(UUID().uuidString).mp4"
    let command = makeScreenRecordCommand(
      bitRateMbps: bitRateMbps,
      timeLimitSeconds: timeLimitSeconds,
      size: sizeHint,
      destination: remote,
      bugReport: bugReport
    )

    let (connection, pidValue) = try await withTimeout(recordingTimeouts.command).runWithRetry(maxAttempts: 1) { connection in
      try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
          continuation.resume(with: Result {
            try connection.sendTransport(to: deviceID)
            try connection.sendShell("sh -c 'echo $$; exec \(command)'")
            guard let pidLine = try connection.readLine(),
                  let pid = Int32(pidLine.trimmingCharacters(in: .whitespacesAndNewlines)) else {
              throw ADBError.parseFailure("Unable to determine screenrecord pid")
            }
            return (connection, pid)
          })
        }
      }
    }

    return RecordingSession(
      deviceID: deviceID,
      remotePath: remote,
      pid: pidValue,
      connection: connection,
      startedAt: Date()
    )
  }

  /// Returns a finalization warning when a recording was still downloaded successfully.
  @discardableResult
  public func stopScreenrecord(session: RecordingSession, savingTo localURL: URL) async throws -> Error? {
    defer { session.close() }
    var warning: Error?
    do {
      try await sendSigInt(deviceID: session.deviceID, pid: session.pid)
      try await session.waitUntilStopped(timeout: recordingTimeouts.finalization)
    } catch {
      try Task.checkCancellation()
      warning = error
    }
    // A missing shell exit does not prove the recording is unreadable.
    try await collectScreenrecord(session: session, savingTo: localURL)
    return warning
  }

  public func collectScreenrecord(session: RecordingSession, savingTo localURL: URL) async throws {
    defer { session.close() }
    do {
      try await withTimeout(recordingTimeouts.download).pull(
        deviceID: session.deviceID, remote: session.remotePath, to: localURL,
        idleTimeout: recordingTimeouts.downloadIdle
      )
    } catch {
      try? FileManager.default.removeItem(at: localURL)
      // Keep the device copy when a download fails so it can be recovered later.
      if case ADBError.requestTimedOut = error {
        throw ADBError.requestTimedOut("Recording download timed out.")
      }
      throw error
    }
    await removeRemoteRecording(session)
  }

  public func cancelScreenrecord(session: RecordingSession) async {
    defer { session.close() }
    try? await sendSigInt(deviceID: session.deviceID, pid: session.pid)
    try? await session.waitUntilStopped(timeout: recordingTimeouts.finalization)
    await removeRemoteRecording(session)
  }

  func discardScreenrecord(session: RecordingSession) async {
    await removeRemoteRecording(session)
    session.close()
  }

  private func removeRemoteRecording(_ session: RecordingSession) async {
    _ = try? await withTimeout(recordingTimeouts.command).runShellString(
      deviceID: session.deviceID,
      command: "rm -f \(session.remotePath)"
    )
  }

  public func startScreenStream(deviceID: String, bitRateMbps: Int = 8) async throws -> ScreenStreamSession {
    #if PERF_TRACING
    let timing = Perf.startupBegin("adb screen stream setup", deviceID: deviceID)
    defer { Perf.startupEnd(timing) }
    #endif

    let sizeHint = try? await displaySize(deviceID: deviceID)
    let command = makeScreenRecordCommand(
      bitRateMbps: bitRateMbps,
      timeLimitSeconds: 0,
      size: sizeHint,
      destination: "-",
      outputFormat: "h264"
    )

    let connection = try await makeConnection()
    do {
      try connection.sendTransport(to: deviceID)
      try connection.sendShell(command)
    } catch {
      connection.close()
      throw error
    }

    #if PERF_TRACING
    Perf.startupEvent("adb screen socket open", deviceID: deviceID)
    #endif
    #if PERF_TRACING
    let wakeTiming = Perf.startupBegin("adb wake", deviceID: deviceID)
    #endif
    _ = try? await keyEvent(deviceID: deviceID, keyCode: "KEYCODE_WAKEUP")
    #if PERF_TRACING
    Perf.startupEnd(wakeTiming)
    #endif
    return ScreenStreamSession(
      deviceID: deviceID,
      connection: connection,
      startedAt: Date()
    )
  }

  func isBootComplete(deviceID: String) async throws -> Bool {
    #if PERF_TRACING
    let timing = Perf.startupBegin("adb boot check", deviceID: deviceID)
    defer { Perf.startupEnd(timing) }
    #endif
    let value = try await runDiscoveryShellString(deviceID: deviceID, command: "getprop sys.boot_completed")
    return value.trimmingCharacters(in: .whitespacesAndNewlines) == "1"
  }

  public func displaySize(deviceID: String) async throws -> String {
    #if PERF_TRACING
    let timing = Perf.startupBegin("adb display size", deviceID: deviceID)
    defer { Perf.startupEnd(timing) }
    #endif
    let result = try await runShellString(deviceID: deviceID, command: "dumpsys window displays")
    guard let match = result.firstMatch(of: /cur=(?<size>\d+x\d+)/) else {
      throw ADBError.parseFailure("Unable to find window size")
    }
    return String(match.output.size)
  }

  public func displayDensity(deviceID: String) async throws -> Double {
    #if PERF_TRACING
    let timing = Perf.startupBegin("adb density", deviceID: deviceID)
    defer { Perf.startupEnd(timing) }
    #endif

    if let wmOutput = try? await runShellString(deviceID: deviceID, command: "wm density"),
       let density = parseDensity(from: wmOutput) {
      return density
    }

    if let prop = try? await runShellString(deviceID: deviceID, command: "getprop ro.sf.lcd_density"),
       let density = parseDensity(from: prop) {
      return density
    }

    throw ADBError.parseFailure("Unable to determine device density")
  }

  @discardableResult
  public func keyEvent(deviceID: String, keyCode: String) async throws -> String {
    try await runShellString(deviceID: deviceID, command: "input keyevent \(keyCode)")
  }

  public func getProp(deviceID: String, key: String) async throws -> String {
    try await runShellString(deviceID: deviceID, command: "getprop \(key)")
  }

  public func setShowTouches(deviceID: String, enabled: Bool) async throws {
    _ = try await runShellString(
      deviceID: deviceID,
      command: "settings put system show_touches \(enabled ? "1" : "0")"
    )
  }

  public func getShowTouches(deviceID: String) async throws -> Bool {
    let value = try await runShellString(
      deviceID: deviceID,
      command: "settings get system show_touches"
    ).trimmingCharacters(in: .whitespacesAndNewlines)
    return value == "1"
  }

  public func pull(deviceID: String, remote: String, to localURL: URL) async throws {
    try await pull(deviceID: deviceID, remote: remote, to: localURL, idleTimeout: nil)
  }

  private func pull(deviceID: String, remote: String, to localURL: URL, idleTimeout: Duration?) async throws {
    try FileManager.default.createDirectory(
      at: localURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )

    try await withConnection { connection in
      try connection.setIOTimeout(idleTimeout)
      try connection.sendTransport(to: deviceID)
      try connection.sendSync()
      try connection.sendSyncRequest(id: "RECV", path: remote)

      if FileManager.default.fileExists(atPath: localURL.path) {
        try FileManager.default.removeItem(at: localURL)
      }
      FileManager.default.createFile(atPath: localURL.path, contents: nil)

      guard let handle = FileHandle(forWritingAtPath: localURL.path) else {
        throw ADBError.protocolFailure("unable to open destination file for pull")
      }
      defer { try? handle.close() }

      try connection.readSyncData { chunk in
        try handle.write(contentsOf: chunk)
      }
    }
  }

  public func getProperties(deviceID: String, prefix: String? = nil) async throws -> [String: String] {
    #if PERF_TRACING
    let timing = Perf.startupBegin("adb properties", deviceID: deviceID)
    defer { Perf.startupEnd(timing) }
    #endif
    let output = try await runDiscoveryShellString(deviceID: deviceID, command: "getprop")
    var result: [String: String] = [:]
    for line in output.split(separator: "\n") {
      guard let property = parsePropertyLine(line) else { continue }
      if let prefix {
        if property.key.hasPrefix(prefix) { result[property.key] = property.value }
      } else {
        result[property.key] = property.value
      }
    }
    return result
  }

  public func trackDevices() async throws -> (
    handle: TrackDevicesHandle,
    stream: AsyncThrowingStream<String, Error>
  ) {
    #if PERF_TRACING
    let timing = Perf.startupBegin("adb track setup")
    defer { Perf.startupEnd(timing) }
    #endif
    let connection = try await runWithRetry(maxAttempts: 3) { connection in
      // Keep setup inside the cancellation handler so a stalled reply releases the socket.
      try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
          continuation.resume(with: Result {
            try connection.withRequestTimeout(discoveryTimeout) {
              try connection.sendTrackDevices()
            }
            return connection
          })
        }
      }
    }

    let stream = AsyncThrowingStream<String, Error> { continuation in
      let streamTask = Task.detached(priority: .userInitiated) {
        do {
          while !Task.isCancelled {
            guard let payload = try connection.readLengthPrefixedPayload() else { break }
            guard let payloadString = String(bytes: payload, encoding: .utf8) else { break }
            #if PERF_TRACING
            Perf.startupEvent("adb device list received")
            #endif
            continuation.yield(payloadString)
          }
          continuation.finish()
        } catch {
          // Closing a cancelled reader can also surface a socket error.
          continuation.finish(throwing: Task.isCancelled ? nil : error)
        }
      }

      continuation.onTermination = { _ in
        streamTask.cancel()
        connection.close()
      }
    }

    let handle = TrackDevicesHandle {
      connection.close()
    }

    return (handle, stream)
  }

  public func devicesList() async throws -> String {
    try await withConnection { connection in
      try connection.withRequestTimeout(discoveryTimeout) {
        try connection.sendDevicesList()
        guard let payload = try connection.readLengthPrefixedPayload() else { return "" }
        return String(data: payload, encoding: .utf8) ?? ""
      }
    }
  }

  func emulatorConnections(checkBoot: Bool = true) async throws -> [EmulatorConnection] {
    let connections = try await EmulatorConnection.parse(devicesList())
    guard checkBoot else { return connections }
    let checked = await withTaskGroup(of: EmulatorConnection.self) { group in
      for connection in connections {
        group.addTask {
          var connection = connection
          if connection.state == .starting,
             await (try? isBootComplete(deviceID: connection.serial)) == true {
            connection.state = .running
          }
          return connection
        }
      }
      var result: [EmulatorConnection] = []
      for await connection in group {
        result.append(connection)
      }
      return result
    }
    try Task.checkCancellation()
    let current = try await EmulatorConnection.parse(devicesList())
    return EmulatorConnection.reconcileBootChecks(checked, current: current)
  }

  public func connectedDeviceIDs() async throws -> [String] {
    try await DeviceDiscovery.connectedDeviceIDs(inDevicesList: devicesList())
  }

  public func listUnixSockets(deviceID: String) async throws -> String {
    try await runDiscoveryShellString(deviceID: deviceID, command: "cat /proc/net/unix")
  }

  public func pluginMetadata(
    deviceID: String,
    processIDs: [Int],
    helperURL: URL
  ) async throws -> [ToolProcessMetadata] {
    let command = try ToolManifestReader.metadataCommand(helper: Data(contentsOf: helperURL), processIDs: processIDs)
    let data = try await runPluginReader(deviceID: deviceID, command: command, maximumBytes: 8_388_608)
    return try ToolManifestReader.decode(data)
  }

  public func pluginFrontend(
    deviceID: String,
    socketName: String,
    manifest: ToolProcessMetadata,
    tool: ToolDescriptor,
    helperURL: URL
  ) async throws -> ToolFrontendBundle {
    guard let identity = ToolProcessIdentity(metadata: manifest) else {
      throw ADBError.parseFailure("invalid tool process identity")
    }
    return try await pluginFrontend(
      deviceID: deviceID, socketName: socketName, identity: identity, tool: tool, helperURL: helperURL
    )
  }

  public func pluginFrontend(
    deviceID: String,
    socketName: String,
    identity: ToolProcessIdentity,
    tool: ToolDescriptor,
    helperURL: URL
  ) async throws -> ToolFrontendBundle {
    guard tool.frontend != nil, socketName == "snapo_\(tool.id.rawValue)_\(identity.pid)" else {
      throw ADBError.parseFailure("invalid tool frontend request")
    }
    let expected = try ToolFrontendBundle.request(identity: identity, tool: tool)
    let command = try ToolManifestReader.frontendCommand(
      helper: Data(contentsOf: helperURL),
      socketName: socketName,
      request: expected
    )
    let data = try await runPluginReader(deviceID: deviceID, command: command, maximumBytes: 16 * 1024 * 1024)
    return try ToolFrontendBundle(archive: data)
  }

  public func legacyPluginMetadata(
    reference: ToolServerReference, kind: ToolID, pid: Int
  ) async throws -> LegacyPluginMetadata? {
    guard pid > 0, reference.socketName == "snapo_\(kind.rawValue)_\(pid)",
          let request = LegacyPluginReader.request(kind: kind) else { return nil }
    try Task.checkCancellation()
    do {
      return try await withConnection(maxAttempts: 1) { connection in
        try connection.withRequestTimeout(.seconds(2)) {
          try connection.sendTransport(to: reference.deviceId)
          try connection.sendLocalAbstract(reference.socketName)
          try connection.writeLine(String(request.dropLast()))
          let http = request.hasPrefix("GET ")
          let deadline = ContinuousClock.now.advanced(by: .seconds(2))
          var bytes = Data()
          while true {
            let chunk = try connection.readChunk(maxLength: 16384, deadline: deadline)
            if let chunk { bytes.append(chunk) }
            if let payload = try LegacyPluginReader.payload(bytes, http: http, ended: chunk == nil) {
              return try LegacyPluginReader.decode(payload, kind: kind, pid: pid, http: http)
            }
            if chunk == nil { return nil }
          }
        }
      }
    } catch {
      try Task.checkCancellation()
      // A failed probe is not evidence that the app uses an old library.
      return nil
    }
  }

  private func runPluginReader(deviceID: String, command: String, maximumBytes: Int) async throws -> Data {
    try await withConnection(maxAttempts: 1) { connection in
      try connection.withRequestTimeout(.seconds(10)) {
        try connection.sendTransport(to: deviceID)
        try connection.sendShell(command)
        var output = Data()
        while let chunk = try connection.readChunk(maxLength: 16384) {
          guard output.count + chunk.count <= maximumBytes else {
            throw ADBError.parseFailure("tool resource output is too large")
          }
          output.append(chunk)
        }
        return output
      }
    }
  }

  public func openLocalAbstract(
    deviceID: String,
    abstractSocket: String
  ) async throws -> ADBSocketConnection {
    try await runWithRetry(maxAttempts: 1) { connection in
      try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
          continuation.resume(with: Result {
            try connection.withRequestTimeout(discoveryTimeout) {
              try connection.sendTransport(to: deviceID)
              try connection.sendLocalAbstract(abstractSocket)
            }
            return connection
          })
        }
      }
    }
  }

  /// Opens a connection for transports that need direct control of the ADB protocol.
  public func makeConnection(maxAttempts: Int = 3) async throws -> ADBSocketConnection {
    try await runWithRetry(maxAttempts: maxAttempts) { connection in connection }
  }

  // MARK: - Private helpers

  func runDiscoveryShellString(deviceID: String, command: String) async throws -> String {
    let data = try await withConnection { connection in
      try connection.withRequestTimeout(discoveryTimeout) {
        try connection.sendTransport(to: deviceID)
        try connection.sendShell(command)
        return try connection.readToEnd()
      }
    }
    guard let output = String(data: data, encoding: .utf8) else {
      throw ADBError.parseFailure("non-utf8 output from adb")
    }
    return output
  }

  private func runShellData(deviceID: String, command: String) async throws -> Data {
    try await withConnection { connection in
      try connection.sendTransport(to: deviceID)
      try connection.sendShell(command)
      return try connection.readToEnd()
    }
  }

  public func runShellString(deviceID: String, command: String) async throws -> String {
    let data = try await runShellData(deviceID: deviceID, command: command)
    guard let output = String(data: data, encoding: .utf8) else {
      throw ADBError.parseFailure("non-utf8 output from adb")
    }
    return output
  }

  func withConnection<T: Sendable>(
    maxAttempts: Int = 3,
    _ body: @escaping @Sendable (ADBSocketConnection) throws -> T
  ) async throws -> T {
    try await runWithRetry(maxAttempts: maxAttempts) { connection in
      // Blocking ADB I/O must not occupy Swift's cooperative executor threads.
      try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
          let result = Result { try body(connection) }
          connection.close()
          continuation.resume(with: result)
        }
      }
    }
  }

  private func runWithRetry<T: Sendable>(
    maxAttempts: Int,
    _ operation: @escaping @Sendable (ADBSocketConnection) async throws -> T
  ) async throws -> T {
    var lastError: Error?

    for attempt in 0 ..< maxAttempts {
      try Task.checkCancellation()

      do {
        let connection = try connectionFactory()
        do {
          let value = try await withTaskCancellationHandler {
            try await perform(operation, on: connection)
          } onCancel: {
            connection.close()
          }
          try Task.checkCancellation()
          return value
        } catch {
          connection.close()
          throw error
        }
      } catch {
        if Task.isCancelled { throw CancellationError() }
        let normalized = normalize(error)
        lastError = normalized

        guard shouldRetryConnection(after: normalized), attempt + 1 < maxAttempts else { throw normalized }

        let backoff = UInt64(min(1_000_000_000, 100_000_000 << attempt))
        try await Task.sleep(nanoseconds: backoff)
      }
    }

    throw lastError ?? ADBError.serverUnavailable("Failed to communicate with adb server")
  }

  private func perform<T: Sendable>(
    _ operation: @escaping @Sendable (ADBSocketConnection) async throws -> T,
    on connection: ADBSocketConnection
  ) async throws -> T {
    guard let requestTimeout else { return try await operation(connection) }
    return try await withThrowingTaskGroup(of: T.self) { group in
      group.addTask {
        try await withTaskCancellationHandler {
          try await operation(connection)
        } onCancel: {
          // Cancelling a task alone does not interrupt a blocking socket read.
          connection.close()
        }
      }
      group.addTask {
        try await Task.sleep(for: requestTimeout)
        throw ADBError.requestTimedOut("Recording request timed out.")
      }
      defer { group.cancelAll() }
      guard let value = try await group.next() else { throw CancellationError() }
      return value
    }
  }

  private func sendSigInt(deviceID: String, pid: Int32) async throws {
    let command = "kill -INT \(pid) >/dev/null 2>&1 || true"
    _ = try await withTimeout(recordingTimeouts.command).runShellString(deviceID: deviceID, command: command)
  }

  private func makeScreenRecordCommand(
    bitRateMbps: Int,
    timeLimitSeconds: Int,
    size: String?,
    destination: String,
    outputFormat: String? = nil,
    bugReport: Bool = false
  ) -> String {
    var command = "screenrecord --bit-rate \(bitRateMbps * 1_000_000) --time-limit \(timeLimitSeconds)"
    if let outputFormat, !outputFormat.isEmpty { command += " --output-format=\(outputFormat)" }
    if let size, !size.isEmpty { command += " --size \(size)" }
    if bugReport { command += " --bugreport" }
    command += " \(destination)"
    return command
  }

  private func parseDensity(from value: String) -> Double? {
    if let match = value.firstMatch(of: /Physical density:\s*(\d+)/),
       let number = Double(match.1) {
      return number / 160.0
    }

    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    if let number = Double(trimmed) {
      return number / 160.0
    }
    return nil
  }

  private func parsePropertyLine(_ line: Substring) -> (key: String, value: String)? {
    guard let keyStart = line.firstIndex(of: "["),
          let keyEnd = line[keyStart...].firstIndex(of: "]"),
          let valueStart = line[keyEnd...].firstIndex(of: "["),
          let valueEnd = line[valueStart...].firstIndex(of: "]")
    else { return nil }

    let keyRange = line.index(after: keyStart) ..< keyEnd
    let valueRange = line.index(after: valueStart) ..< valueEnd

    return (
      key: String(line[keyRange]),
      value: String(line[valueRange])
    )
  }

  private func shouldRetryConnection(after error: Error) -> Bool {
    if let adbError = error as? ADBError {
      if case .serverUnavailable = adbError { return true }
      return false
    }
    if error is POSIXError { return true }
    if (error as NSError).domain == NSPOSIXErrorDomain { return true }
    return false
  }

  private func normalize(_ error: Error) -> Error {
    if let adbError = error as? ADBError { return adbError }
    if let posix = error as? POSIXError {
      return ADBError.serverUnavailable(posix.localizedDescription)
    }
    if (error as NSError).domain == NSPOSIXErrorDomain {
      return ADBError.serverUnavailable((error as NSError).localizedDescription)
    }
    return error
  }
}

public struct TrackDevicesHandle: Sendable {
  private let cancelClosure: @Sendable () -> Void

  init(_ cancelClosure: @escaping @Sendable () -> Void) {
    self.cancelClosure = cancelClosure
  }

  public func cancel() {
    cancelClosure()
  }
}
