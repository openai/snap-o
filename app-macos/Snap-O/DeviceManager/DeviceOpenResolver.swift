import Foundation

struct DeviceLinkConnection: Equatable {
  var server: DeviceLinkServer
  var isEnabled = true
  var state: ADBServerState = .connecting
  /// Nil means this server has not published its first device list yet.
  var connectedSerials: Set<String>?
}

struct DeviceOpenSnapshot {
  var connectedDeviceIDs: Set<String> = []
  var servers: [ADBServerID: DeviceLinkConnection] = [:]
  var emulators: [ManagedEmulator] = []
  var hasLoaded = false
  var isRefreshing = false
  var loadError: String?
  var actions: [String: String] = [:]
  var launchErrors: [String: String] = [:]
}

struct DeviceOpenError: LocalizedError {
  let message: String
  var errorDescription: String? {
    message
  }
}

@MainActor
struct DeviceOpenResolver {
  let snapshot: () -> DeviceOpenSnapshot
  let start: (ManagedEmulator) -> Void
  var wait: () async throws -> Void = { try await Task.sleep(for: .milliseconds(200)) }
  var timeout: Duration = .seconds(180)

  func resolve(_ request: DeviceOpenRequest, progress: (String) -> Void) async throws -> String {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    switch request {
    case .serial(let serial, let server, let serverID):
      return try await resolveSerial(serial, server: server, serverID: serverID, deadline: deadline, progress: progress)
    case .device(let id):
      return try await resolveDevice(id, deadline: deadline, progress: progress)
    case .avd(let name, let shouldStart):
      return try await resolveAVD(name, shouldStart: shouldStart, deadline: deadline, progress: progress)
    }
  }

  private func selectServer(matching server: DeviceLinkServer) throws -> (id: ADBServerID, server: DeviceLinkServer) {
    let matches = snapshot().servers.filter { server.matches($0.value.server) }
    guard !matches.isEmpty else {
      throw DeviceOpenError(message: "No configured ADB server matches this link.")
    }
    let enabled = matches.filter(\.value.isEnabled)
    guard let match = enabled.first else {
      throw DeviceOpenError(message: "The matching ADB server is disabled.")
    }
    guard enabled.count == 1 else {
      throw DeviceOpenError(message: "More than one enabled ADB server matches this link. Specify its SSH port.")
    }
    return (match.key, match.value.server)
  }

  private func resolveSerial(
    _ serial: String, server: DeviceLinkServer, serverID: ADBServerID?,
    deadline: ContinuousClock.Instant, progress: (String) -> Void
  ) async throws -> String {
    try Task.checkCancellation()
    let selectedServer = try serverID.map { (id: $0, server: server) } ?? selectServer(matching: server)
    var serverWasOnline = false
    while true {
      try Task.checkCancellation()
      let state = snapshot()
      guard let connection = state.servers[selectedServer.id] else {
        throw DeviceOpenError(message: "The selected ADB server disconnected while opening the device.")
      }
      guard connection.server == selectedServer.server else {
        throw DeviceOpenError(message: "The selected ADB server connection changed while opening the device.")
      }
      guard connection.isEnabled else {
        throw DeviceOpenError(message: "The selected ADB server is disabled.")
      }
      switch connection.state {
      case .unavailable(let reason):
        throw DeviceOpenError(message: "ADB server connection failed: \(reason)")
      case .connecting, .starting:
        guard !serverWasOnline else {
          throw DeviceOpenError(message: "The selected ADB server disconnected while opening the device.")
        }
        progress("Connecting")
      case .online:
        serverWasOnline = true
        if let serials = connection.connectedSerials {
          guard serials.contains(serial) else {
            throw DeviceOpenError(message: "“\(serial)” is not connected to the selected ADB server.")
          }
          let id = DeviceID(serverID: selectedServer.id, serial: serial)
          if state.connectedDeviceIDs.contains(id.storedValue) { return id.storedValue }
        }
        progress("Finding device")
      }
      try await waitForUpdate(deadline: deadline, name: serial)
    }
  }

  private func resolveDevice(_ id: DeviceID, deadline: ContinuousClock.Instant, progress: (String) -> Void) async throws -> String {
    while true {
      try Task.checkCancellation()
      if snapshot().connectedDeviceIDs.contains(id.storedValue) { return id.storedValue }
      progress("Connecting")
      try await waitForUpdate(deadline: deadline, name: id.serial)
    }
  }

  private func resolveAVD(
    _ name: String, shouldStart: Bool, deadline: ContinuousClock.Instant, progress: (String) -> Void
  ) async throws -> String {
    var launchedID: String?
    while true {
      try Task.checkCancellation()
      let state = snapshot()
      let matches = state.emulators.filter { $0.avdName == name }
      guard matches.count <= 1 else {
        throw DeviceOpenError(message: "More than one emulator is named “\(name)”. Open it from Device Manager.")
      }
      if let device = matches.first {
        if let error = state.launchErrors[device.id], launchedID == device.id {
          throw DeviceOpenError(message: error)
        }
        if device.state == .stopping || state.actions[device.id] == "Deleting" {
          throw DeviceOpenError(message: "“\(name)” is busy. Try again after its current action finishes.")
        }
        if let serial = device.serial, state.connectedDeviceIDs.contains(serial),
           device.state == .running || device.state == .starting || device.state == .offline {
          return serial
        }
        if let action = state.actions[device.id] {
          progress(action)
        } else if device.canStart, state.isRefreshing {
          progress("Finding emulator")
        } else if device.canStart {
          guard shouldStart else {
            throw DeviceOpenError(message: "“\(name)” is stopped. Start it in Device Manager or add start=true to the link.")
          }
          guard launchedID == nil else {
            throw DeviceOpenError(message: device.detail ?? "“\(name)” stopped before it was ready.")
          }
          if let error = state.loadError { throw DeviceOpenError(message: error) }
          launchedID = device.id
          start(device)
          progress("Starting")
        } else {
          progress(device.state == .starting ? "Booting" : "Connecting")
        }
      } else if let error = state.loadError {
        throw DeviceOpenError(message: error)
      } else if state.hasLoaded {
        throw DeviceOpenError(message: "No installed emulator is named “\(name)”.")
      } else {
        progress("Finding emulator")
      }
      try await waitForUpdate(deadline: deadline, name: name)
    }
  }

  private func waitForUpdate(deadline: ContinuousClock.Instant, name: String) async throws {
    guard ContinuousClock.now < deadline else {
      throw DeviceOpenError(message: "“\(name)” did not become available. Check Device Manager and try again.")
    }
    try await wait()
  }
}
