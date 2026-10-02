import Foundation
@testable import Snap_O
import Testing

@MainActor
struct CaptureDevicePickerTests {
  @Test(arguments: [ManagedEmulator.State.starting, .offline])
  func includesBootingEmulatorWithoutSerial(state: ManagedEmulator.State) throws {
    let option = try #require(CaptureDeviceOption(entry: .emulator(emulator(state)), startupStatus: "Connecting"))
    #expect(option.serial == nil)
    #expect(option.request == .avd("Pixel_API_35", start: false))
    #expect(option.matches(.avd("Pixel_API_35", start: true)))
    #expect(option.status == "Connecting")
  }

  @Test func includesLaunchBeforeInventoryUpdates() throws {
    let option = try #require(CaptureDeviceOption(entry: .emulator(emulator(.stopped)), startupStatus: "Starting"))
    #expect(option.title == "Pixel")
    #expect(option.status == "Starting")
  }

  @Test func excludesStoppedUnavailableAndStoppingEmulators() {
    for state in [ManagedEmulator.State.stopped, .unavailable, .stopping] {
      #expect(CaptureDeviceOption(entry: .emulator(emulator(state)), startupStatus: nil) == nil)
    }
    #expect(CaptureDeviceOption(entry: .emulator(emulator(.running)), startupStatus: "Deleting") == nil)
  }

  @Test func matchesSelectedSerialAfterConnection() throws {
    let option = try #require(CaptureDeviceOption(
      entry: .emulator(emulator(.starting, serial: "emulator-5554")), startupStatus: "Booting"
    ))
    #expect(option.matches(.serial("emulator-5554")))
    #expect(!option.matches(.serial("emulator-5556")))
    #expect(!option.matches(.avd("Other", start: false)))
  }

  @Test func includesConnectedPhone() throws {
    let device = Device(id: "phone", model: "Phone", androidVersion: "16", vendorModel: nil, manufacturer: nil, avdName: nil)
    let option = try #require(CaptureDeviceOption(entry: .connected(device), startupStatus: nil))
    #expect(option.request == .serial("phone"))
    #expect(option.matches(.serial("phone")))
    #expect(option.status == nil)
  }

  private func emulator(_ state: ManagedEmulator.State, serial: String? = nil) -> ManagedEmulator {
    ManagedEmulator(
      id: "/synthetic/Pixel.avd", avdName: "Pixel_API_35", title: "Pixel",
      platform: "Android 15", architecture: "arm64", state: state, serial: serial
    )
  }
}
