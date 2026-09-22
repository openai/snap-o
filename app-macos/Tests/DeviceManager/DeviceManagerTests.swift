import Foundation

@main
struct DeviceManagerTests {
  static func main() {
    connectedDevicesComeFirst()
    emulatorsAppearOnlyOnce()
    bootingEmulatorsAppearOnlyOnce()
    unmatchedDevicesRemainVisible()
    additionalEmulatorInstancesRemainVisible()
    devicesWithUnknownConsoleIdentityRemainVisible()
    print("Device Manager list tests passed (6 tests)")
  }

  private static func connectedDevicesComeFirst() {
    let entries = DeviceManagerEntry.list(emulators: [emulator(serial: nil)], connectedDevices: [phone("phone")])
    precondition(entries.map(\.id) == ["device:phone", "emulator:avd"], "Connected devices must precede offline emulators")
  }

  private static func emulatorsAppearOnlyOnce() {
    let entries = DeviceManagerEntry.list(
      emulators: [emulator(serial: "emulator-5554")], connectedDevices: [phone("emulator-5554")]
    )
    precondition(entries.map(\.id) == ["emulator:avd"], "ADB and AVD discovery must produce one emulator row")
  }

  private static func bootingEmulatorsAppearOnlyOnce() {
    var booting = emulator(serial: nil)
    booting.state = .starting
    let connected = phone("emulator-5554", avdName: "Test Device")
    let before = DeviceManagerEntry.list(emulators: [booting], connectedDevices: [])
    let during = DeviceManagerEntry.list(emulators: [booting], connectedDevices: [connected])
    booting.serial = connected.id
    let after = DeviceManagerEntry.list(emulators: [booting], connectedDevices: [connected])
    precondition(before.map(\.id) == ["emulator:avd"])
    precondition(during.map(\.id) == before.map(\.id), "Early ADB discovery must preserve one stable booting row")
    precondition(after.map(\.id) == before.map(\.id), "Learning the serial must preserve the row identity")
  }

  private static func unmatchedDevicesRemainVisible() {
    let devices = [
      phone("phone", avdName: "Test Device"),
      phone("emulator-5554", avdName: "Other Device"),
      phone("emulator-5556")
    ]
    var booting = emulator(serial: nil)
    booting.state = .starting
    let entries = DeviceManagerEntry.list(emulators: [booting], connectedDevices: devices)
    precondition(entries.count == 4, "Phones and emulators without a matching AVD must remain visible")
  }

  private static func additionalEmulatorInstancesRemainVisible() {
    let devices = [phone("emulator-5554", avdName: "Test Device"), phone("emulator-5556", avdName: "Test Device")]
    for serial: String? in [nil, "emulator-5554", "emulator-5556"] {
      var managed = emulator(serial: serial)
      if serial == nil { managed.state = .starting }
      let entries = DeviceManagerEntry.list(emulators: [managed], connectedDevices: devices)
      precondition(entries.count == 2, "Each AVD row must replace at most one connected emulator")
      if let serial {
        precondition(!entries.contains { $0.id == "device:" + serial }, "An exact serial match takes priority")
      }
    }
  }

  private static func devicesWithUnknownConsoleIdentityRemainVisible() {
    let connected = phone("emulator-5554", avdName: "Test Device")
    var managed = emulator(serial: nil)
    let states: [ManagedEmulator.State] = [.stopped, .unavailable, .offline, .stopping, .running, .starting]
    for state in states {
      managed.state = state
      managed.detail = state == .starting ? "Startup is taking longer than expected. Check the emulator log." : nil
      let entries = DeviceManagerEntry.list(emulators: [managed], connectedDevices: [connected])
      precondition(entries.count == 2, "Only transient startup may hide a name-matched ADB connection")
      precondition(
        entries.contains { $0.id == "device:" + connected.id && $0.isRunning && $0.serial == connected.id },
        "A usable ADB connection must retain its Open action when console identity is unknown"
      )
    }
  }

  private static func phone(_ id: String, avdName: String? = nil) -> Device {
    Device(id: id, model: "Z Phone", androidVersion: "16", vendorModel: nil, manufacturer: nil, avdName: avdName)
  }

  private static func emulator(serial: String?) -> ManagedEmulator {
    ManagedEmulator(
      id: "avd", avdName: "Test_Device", title: "A Emulator", platform: "API 36", architecture: "arm64-v8a",
      state: serial == nil ? .stopped : .running, serial: serial
    )
  }
}
