import Foundation

struct EmulatorConnection: Equatable {
  let serial: String
  let transportID: String?
  var state: ManagedEmulator.State

  static func parse(_ devices: String) -> [Self] {
    devices.split(whereSeparator: \.isNewline).compactMap { line in
      let fields = line.split(whereSeparator: \.isWhitespace)
      guard fields.count >= 2, fields[0].hasPrefix("emulator-"),
            let port = UInt16(fields[0].dropFirst(9)), port >= 1024 else { return nil }
      let transport = fields.dropFirst(2).first { $0.hasPrefix("transport_id:") }
      return Self(
        serial: String(fields[0]), transportID: transport.map { String($0.dropFirst(13)) },
        state: fields[1] == "device" ? .starting : .offline
      )
    }
  }

  /// Boot checks may finish after ADB reuses a serial for another emulator.
  static func reconcileBootChecks(_ checked: [Self], current: [Self]) -> [Self] {
    current.map { connection in
      guard connection.state == .starting,
            let previous = checked.first(where: { $0.serial == connection.serial }),
            previous.transportID == connection.transportID, previous.state == .running else { return connection }
      return previous
    }
  }

  static func applying(_ connections: [Self], to inventory: EmulatorInventory) -> [ManagedEmulator] {
    inventory.devices.map { device in
      var device = device
      guard device.state == .offline, let serial = device.serial else { return device }
      device.state = connections.first { $0.serial == serial }?.state ?? .offline
      return device
    }
  }
}
