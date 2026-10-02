import Foundation

struct DeviceOpenSnapshot {
  var connectedSerials: Set<String> = []
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
    var launchedID: String?
    while true {
      try Task.checkCancellation()
      let state = snapshot()
      switch request {
      case .serial(let serial):
        if state.connectedSerials.contains(serial) { return serial }
        progress("Connecting")
      case .avd(let name, let shouldStart):
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
          if let serial = device.serial, state.connectedSerials.contains(serial),
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
      }
      guard ContinuousClock.now < deadline else {
        throw DeviceOpenError(message: "“\(request.name)” did not become available. Check Device Manager and try again.")
      }
      try await wait()
    }
  }
}
