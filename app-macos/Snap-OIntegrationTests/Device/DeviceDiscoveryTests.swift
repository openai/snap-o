@testable import Snap_O
import Testing

@Suite("Device discovery")
struct DeviceDiscoveryTests {
  @Test("extracts process metadata")
  func extractsProcessMetadata() {
    #expect(DeviceDiscovery.processName(inCmdline: "com.example.app\0ignored") == "com.example.app")
  }

  @Test("includes only available devices")
  func parsesDevicesList() {
    let output = """
    emulator-5554 device product:sdk_gphone64_arm64 transport_id:1
    offline-phone offline transport_id:2
    usb-phone device product:oriole transport_id:3
    unauthorized-phone unauthorized transport_id:4
    """

    #expect(
      DeviceDiscovery.connectedDeviceIDs(inDevicesList: output)
        == ["emulator-5554", "usb-phone"]
    )
  }

  @Test("extracts the Android user from the process UID")
  func parsesAndroidUser() {
    #expect(DeviceDiscovery.androidUserID(inProcStatus: "Name:\tdemo\nUid:\t10234\t10234\t10234\t10234\n") == 0)
    #expect(DeviceDiscovery.androidUserID(inProcStatus: "Uid:\t1010234\t1010234\t1010234\t1010234\n") == 10)
    #expect(DeviceDiscovery.androidUserID(inProcStatus: "Uid: 1110234 1110234 1110234 1110234\r\n") == 11)
  }

  @Test("does not assume the current Android user when process metadata is unavailable", arguments: [
    "", "cat: permission denied", "Name:\tdemo\n", "Uid:", "Uid:\t-1", "Uid:\tunknown", "Uid:\t4294967296"
  ])
  func missingAndroidUser(output: String) {
    #expect(DeviceDiscovery.androidUserID(inProcStatus: output) == nil)
  }
}
