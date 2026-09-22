import Foundation

enum DeviceManagerEntry: Identifiable {
  case connected(Device)
  case emulator(ManagedEmulator)

  var id: String {
    switch self {
    case .connected(let device): "device:" + device.id
    case .emulator(let device): "emulator:" + device.id
    }
  }

  var title: String {
    switch self {
    case .connected(let device): device.displayTitle
    case .emulator(let device): device.title
    }
  }

  var subtitle: String {
    switch self {
    case .connected(let device): "Android " + device.androidVersion
    case .emulator(let device):
      [device.platform, device.architecture].filter { !$0.isEmpty }.joined(separator: " · ")
    }
  }

  var serial: String? {
    switch self {
    case .connected(let device): device.id
    case .emulator(let device): device.serial
    }
  }

  var isRunning: Bool {
    switch self {
    case .connected: true
    case .emulator(let device): device.state == .running
    }
  }

  var isTransitioning: Bool {
    guard case .emulator(let device) = self else { return false }
    return device.state == .starting || device.state == .stopping
  }

  var status: String {
    switch self {
    case .connected: "Connected"
    case .emulator(let device): device.state.title
    }
  }

  var detail: String? {
    guard case .emulator(let device) = self else { return nil }
    return device.detail
  }

  static func list(emulators: [ManagedEmulator], connectedDevices: [Device]) -> [Self] {
    var emulatorSerials = Set(emulators.compactMap(\.serial))
    // Hide early ADB duplicates only while startup is progressing without an error or timeout.
    for emulator in emulators where emulator.serial == nil && emulator.state == .starting && emulator.detail == nil {
      let avdName = emulator.avdName.replacingOccurrences(of: "_", with: " ")
      if let device = connectedDevices.first(where: {
        $0.id.hasPrefix("emulator-") && !emulatorSerials.contains($0.id) && $0.avdName == avdName
      }) {
        emulatorSerials.insert(device.id)
      }
    }
    let connectedIDs = Set(connectedDevices.map(\.id))
    let entries = connectedDevices.filter { !emulatorSerials.contains($0.id) }.map(Self.connected)
      + emulators.map(Self.emulator)
    func isConnected(_ entry: Self) -> Bool {
      entry.isRunning || entry.serial.map { connectedIDs.contains($0) } == true
    }
    return entries.sorted { lhs, rhs in
      if isConnected(lhs) != isConnected(rhs) { return isConnected(lhs) }
      let order = lhs.title.localizedStandardCompare(rhs.title)
      return order == .orderedSame ? lhs.id < rhs.id : order == .orderedAscending
    }
  }
}
