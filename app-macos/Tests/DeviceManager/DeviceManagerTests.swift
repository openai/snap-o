import Foundation

@main
struct DeviceManagerTests {
  static func main() {
    connectedDevicesComeFirst()
    emulatorsAppearOnlyOnce()
    print("Device Manager list tests passed (2 tests)")
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

  private static func phone(_ id: String) -> Device {
    Device(id: id, model: "Z Phone", androidVersion: "16", vendorModel: nil, manufacturer: nil, avdName: nil)
  }

  private static func emulator(serial: String?) -> ManagedEmulator {
    ManagedEmulator(
      id: "avd", avdName: "Test", title: "A Emulator", platform: "API 36", architecture: "arm64-v8a",
      state: serial == nil ? .stopped : .running, serial: serial
    )
  }
}
