import Foundation
import SnapODeviceClient

struct CLI {
  private let adb = ADBClient()

  func run(arguments: [String]) async -> Int {
    guard let command = arguments.first else {
      printRootHelp()
      return 0
    }
    if isHelp(command) {
      printRootHelp()
      return 0
    }
    guard command == "network" else {
      CLIOutput.error("Unknown command '\(command)'")
      printRootHelp()
      return 2
    }
    return await runNetwork(arguments: Array(arguments.dropFirst()))
  }

  private func runNetwork(arguments: [String]) async -> Int {
    guard let command = arguments.first else {
      printNetworkHelp()
      return 0
    }
    if isHelp(command) {
      printNetworkHelp()
      return 0
    }

    let options = Array(arguments.dropFirst())
    do {
      switch command {
      case "list":
        if options.contains(where: isHelp) {
          printNetworkListHelp()
          return 0
        }
        return try await list(CLIOptionParser.parseList(options))
      case "requests":
        if options.contains(where: isHelp) {
          printNetworkRequestsHelp()
          return 0
        }
        return try await requests(CLIOptionParser.parseRequests(options))
      case "show":
        if options.contains(where: isHelp) {
          printNetworkShowHelp()
          return 0
        }
        return try await show(CLIOptionParser.parseShow(options))
      default:
        CLIOutput.error("Unknown network command '\(command)'")
        printNetworkHelp()
        return 2
      }
    } catch {
      CLIOutput.error(error.localizedDescription)
      return error is CLIError ? 2 : 1
    }
  }

  private func list(_ options: NetworkListOptions) async throws -> Int {
    let servers = try await discoverServers(selection: options.common.selection)
    guard !servers.isEmpty else { return fail("No Snap-O network servers found") }

    var appInfo: [CLIServerReference: CLIServerAppInfo] = [:]
    if options.includeAppInfo {
      await withTaskGroup(of: (CLIServerReference, CLIServerAppInfo).self) { group in
        for server in servers {
          group.addTask { await (server, resolveAppInfo(server: server)) }
        }
        for await (server, info) in group {
          appInfo[server] = info
        }
      }
    }

    if options.common.json {
      for server in servers {
        let info = appInfo[server]
        try CLIOutput.printJSON(
          ServerListLine(
            server: server.identifier,
            deviceId: server.deviceId,
            socketName: server.socketName,
            packageName: info?.packageName,
            appName: info?.appName
          )
        )
      }
      return 0
    }

    for deviceID in Set(servers.map(\.deviceId)).sorted() {
      CLIOutput.line("\(deviceID):")
      for server in servers.filter({ $0.deviceId == deviceID }).sorted(by: serverSort) {
        if options.includeAppInfo {
          CLIOutput.line("    \(server.socketName)  pkg:\(appInfo[server]?.packageName ?? "unknown")")
        } else {
          CLIOutput.line("    \(server.socketName)")
        }
      }
    }
    return 0
  }

  private func requests(_ options: NetworkRequestsOptions) async throws -> Int {
    guard let server = try await resolveServer(
      socketArgument: options.socketName,
      selection: options.common.selection
    ) else { return 1 }

    let session: CLISession
    do {
      session = try await CLISession.open(server, using: adb)
    } catch {
      return fail("Failed to connect to \(server.identifier)")
    }

    do {
      try await session.startStream()
      var filter = NetworkEventFilter(options.filter)
      let mode: CLIOutputMode = options.common.json ? .json : .human

      if options.noStream {
        let completed = try await emitSnapshot(session: session, filter: &filter, mode: mode)
        await session.close()
        return completed ? 0 : fail("Timed out waiting for snapshot from \(server.identifier)")
      }

      while let record = try await session.nextRecord() {
        if case .network(let message) = record, filter.matches(message) {
          try CLIOutput.emitNetworkEvent(message, mode: mode)
        }
      }
      await session.close()
      return 0
    } catch {
      await session.close()
      throw error
    }
  }

  private func show(_ options: NetworkShowOptions) async throws -> Int {
    guard let requestID = options.requestID?.trimmingCharacters(in: .whitespacesAndNewlines),
          !requestID.isEmpty else {
      return fail("Please specify a request ID with -r/--request-id")
    }
    guard let server = try await resolveServer(
      socketArgument: options.socketName,
      selection: options.common.selection
    ) else { return 1 }

    let result = await RequestDetailsFetcher(
      adb: adb,
      server: server,
      requestID: requestID
    ).fetch()
    switch result {
    case .failure(let message), .missingBody(let message):
      return fail(message)
    case .success(let details):
      if options.common.json {
        try CLIOutput.printJSON(details)
      } else {
        emitHumanDetails(details)
      }
      return 0
    }
  }

  private func emitSnapshot(
    session: CLISession,
    filter: inout NetworkEventFilter,
    mode: CLIOutputMode
  ) async throws -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(5))

    while clock.now < deadline {
      let remaining = clock.now.duration(to: deadline)
      let timeout = min(remaining, .milliseconds(250))
      guard let record = try await session.nextRecord(timeout: timeout) else {
        if await session.isClosed() { return false }
        continue
      }
      switch record {
      case .network(let message) where filter.matches(message):
        try CLIOutput.emitNetworkEvent(message, mode: mode)
      case .replayComplete:
        return true
      default:
        break
      }
    }
    return false
  }

  private func discoverServers(selection: DeviceSelectionOptions) async throws -> [CLIServerReference] {
    let connectedDeviceIDs: [String]
    do {
      connectedDeviceIDs = try await adb.connectedDeviceIDs()
    } catch {
      throw CLIExecutionError("Failed to list adb devices")
    }
    guard !connectedDeviceIDs.isEmpty else { throw CLIExecutionError("No connected devices found") }

    let deviceIDs = try resolveDeviceIDs(connectedDeviceIDs, selection: selection)
    return await NetworkServerDiscovery.discover(on: deviceIDs, using: adb)
  }

  private func resolveDeviceIDs(
    _ connected: [String],
    selection: DeviceSelectionOptions
  ) throws -> [String] {
    let selectionCount = [
      selection.serialID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
      selection.useUSBDevice,
      selection.useEmulator
    ].count { $0 }
    guard selectionCount <= 1 else {
      throw CLIExecutionError("Options -s, -d, and -e are mutually exclusive")
    }

    if let serial = selection.serialID?.trimmingCharacters(in: .whitespacesAndNewlines), !serial.isEmpty {
      guard connected.contains(serial) else { throw CLIExecutionError("Device '\(serial)' is not connected") }
      return [serial]
    }
    if selection.useEmulator {
      let matches = connected.filter { $0.hasPrefix("emulator-") }
      guard !matches.isEmpty else { throw CLIExecutionError("No emulator connected") }
      guard matches.count == 1 else {
        throw CLIExecutionError("More than one emulator connected; use -s <serial>")
      }
      return matches
    }
    if selection.useUSBDevice {
      let matches = connected.filter { !$0.hasPrefix("emulator-") }
      guard !matches.isEmpty else { throw CLIExecutionError("No USB device connected") }
      guard matches.count == 1 else {
        throw CLIExecutionError("More than one USB device connected; use -s <serial>")
      }
      return matches
    }
    return connected
  }

  private func resolveServer(
    socketArgument: String?,
    selection: DeviceSelectionOptions
  ) async throws -> CLIServerReference? {
    let servers = try await discoverServers(selection: selection)
    guard !servers.isEmpty else {
      CLIOutput.error("No Snap-O network servers found for selected device(s)")
      return nil
    }

    guard let socket = socketArgument?.trimmingCharacters(in: .whitespacesAndNewlines), !socket.isEmpty else {
      if servers.count == 1 { return servers[0] }
      let choices = await formatChoices(servers)
      CLIOutput.error("Multiple sockets found; select one with -n/--socket. Available: \(choices)")
      return nil
    }

    if let qualified = parseServerReference(socket) {
      guard let match = servers.first(where: { $0 == qualified }) else {
        CLIOutput.error("Server '\(qualified.identifier)' was not found for selected device(s)")
        return nil
      }
      return match
    }

    let matches = servers.filter { $0.socketName == socket }
    guard !matches.isEmpty else {
      CLIOutput.error("No Snap-O network server named '\(socket)' found")
      return nil
    }
    guard matches.count == 1 else {
      let choices = await formatChoices(matches)
      CLIOutput.error("Socket '\(socket)' exists on multiple devices; use -s <serial>, -d, or -e. Available: \(choices)")
      return nil
    }
    return matches[0]
  }

  private func resolveAppInfo(server: CLIServerReference) async -> CLIServerAppInfo {
    async let packageHint = NetworkServerDiscovery.packageNameHint(for: server, using: adb)
    let appInfo = await fetchAppInfo(server: server)
    let fallbackPackageName = await packageHint
    let appName = appInfo?.processName.trimmingCharacters(in: .whitespacesAndNewlines)
    return CLIServerAppInfo(
      packageName: appInfo?.packageName ?? fallbackPackageName,
      appName: appName?.isEmpty == false ? appName : nil
    )
  }

  private func fetchAppInfo(server: CLIServerReference) async -> NetworkAppInfo? {
    guard let session = try? await CLISession.open(server, using: adb) else { return nil }
    while let record = try? await session.nextRecord(timeout: .milliseconds(1200)) {
      if case .appInfo(let info) = record {
        await session.close()
        return info
      }
    }
    await session.close()
    return nil
  }

  private func formatChoices(_ servers: [CLIServerReference]) async -> String {
    let packages = await withTaskGroup(
      of: (CLIServerReference, String?).self,
      returning: [CLIServerReference: String].self
    ) { group in
      for server in servers {
        group.addTask {
          await (server, NetworkServerDiscovery.packageNameHint(for: server, using: adb))
        }
      }
      var packages: [CLIServerReference: String] = [:]
      for await (server, package) in group {
        packages[server] = package ?? "unknown"
      }
      return packages
    }
    return servers.map { server in
      "\(server.socketName) (pkg:\(packages[server] ?? "unknown"))"
    }.joined(separator: ", ")
  }

  private func parseServerReference(_ value: String) -> CLIServerReference? {
    guard let slash = value.firstIndex(of: "/"),
          slash != value.startIndex,
          slash != value.index(before: value.endIndex) else { return nil }
    let deviceID = String(value[..<slash]).trimmingCharacters(in: .whitespacesAndNewlines)
    let socketName = String(value[value.index(after: slash)...]).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !deviceID.isEmpty, !socketName.isEmpty else { return nil }
    return CLIServerReference(deviceId: deviceID, socketName: socketName)
  }

  private func emitHumanDetails(_ details: RequestDetailsLine) {
    CLIOutput.line("Server: \(details.server)")
    CLIOutput.line("Request ID: \(details.requestId)")
    CLIOutput.line("Request: \(details.requestMethod ?? "unknown") \(details.requestUrl ?? "unknown")")
    CLIOutput.emitHeaders("Request Headers", headers: details.requestHeaders)
    CLIOutput.line("Response: \(details.responseStatus.map(String.init) ?? "unknown") \(details.responseUrl ?? "unknown")")
    CLIOutput.emitHeaders("Response Headers", headers: details.responseHeaders)
    CLIOutput.line("Request Body:")
    CLIOutput.line(
      details.requestBody.map {
        CLIOutput.decodeBodyForDisplay(
          $0,
          encoding: details.requestBodyEncoding,
          contentEncoding: headerValue(details.requestHeaders, named: "Content-Encoding")
        )
      } ?? "<none>"
    )
    CLIOutput.line("Response Body (base64 encoded: \(details.responseBodyBase64Encoded)):")
    CLIOutput.line(details.responseBody)
  }

  private func fail(_ message: String) -> Int {
    CLIOutput.error(message)
    return 1
  }

  private func serverSort(_ left: CLIServerReference, _ right: CLIServerReference) -> Bool {
    if left.deviceId != right.deviceId { return left.deviceId < right.deviceId }
    return left.socketName < right.socketName
  }

  private func isHelp(_ value: String) -> Bool {
    value == "-h" || value == "--help"
  }

  private func printRootHelp() {
    CLIOutput.line("""
    Snap-O command line tools

    Usage:
      snapo network <command> [options]

    Commands:
      network    Inspect Snap-O network data
    """)
  }

  private func printNetworkHelp() {
    CLIOutput.line("""
    Inspect Snap-O network data

    Usage:
      snapo network <command> [options]

    Commands:
      list       List available Snap-O network servers
      requests   Emit CDP network events for a server
      show       Show details for a request id
    """)
  }

  private func printNetworkListHelp() {
    CLIOutput.line("""
    List available Snap-O network servers

    Usage:
      snapo network list [-s <serial> | -d | -e] [--json] [--no-app-info]
    """)
  }

  private func printNetworkRequestsHelp() {
    CLIOutput.line("""
    Emit CDP network events for a server

    Usage:
      snapo network requests [-s <serial> | -d | -e] [-n <socket>] [--filter <text>] [--json] [--no-stream]

    Options:
      --filter <text>  Filter URLs using the Network Inspector search-bar syntax
    """)
  }

  private func printNetworkShowHelp() {
    CLIOutput.line("""
    Show details for a request id

    Usage:
      snapo network show [-s <serial> | -d | -e] [-n <socket>] -r <request-id> [--json]
    """)
  }
}

private struct ServerListLine: Encodable {
  let server: String
  let deviceId: String
  let socketName: String
  let packageName: String?
  let appName: String?

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(server, forKey: .server)
    try container.encode(deviceId, forKey: .deviceId)
    try container.encode(socketName, forKey: .socketName)
    try container.encode(packageName, forKey: .packageName)
    try container.encode(appName, forKey: .appName)
  }

  private enum CodingKeys: String, CodingKey {
    case server
    case deviceId
    case socketName
    case packageName
    case appName
  }
}

private struct CLIExecutionError: LocalizedError {
  let message: String

  init(_ message: String) {
    self.message = message
  }

  var errorDescription: String? {
    message
  }
}
