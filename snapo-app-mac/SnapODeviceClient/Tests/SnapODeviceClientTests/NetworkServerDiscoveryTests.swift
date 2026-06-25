@testable import SnapODeviceClient
import Testing

@Suite("Network server discovery")
struct NetworkServerDiscoveryTests {
  @Test("finds, deduplicates, and sorts Snap-O sockets")
  func parsesProcNetUnix() {
    let output = """
    Num RefCount Protocol Flags Type St Inode Path
    1: 00000002 00000000 00010000 0001 01 1 @snapo_network_42
    2: 00000002 00000000 00010000 0001 01 2 @unrelated
    3: 00000002 00000000 00010000 0001 01 3 @snapo_network_7
    4: 00000002 00000000 00010000 0001 01 4 @snapo_network_42
    """

    #expect(
      NetworkServerDiscovery.socketNames(inProcNetUnix: output)
        == ["snapo_network_42", "snapo_network_7"]
    )
  }

  @Test("extracts process metadata")
  func extractsProcessMetadata() {
    #expect(NetworkServerDiscovery.pid(inSocketName: "snapo_network_321") == 321)
    #expect(NetworkServerDiscovery.pid(inSocketName: "other_321") == nil)
    #expect(NetworkServerDiscovery.packageName(inCmdline: "com.example.app\0ignored") == "com.example.app")
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
      NetworkServerDiscovery.connectedDeviceIDs(inDevicesList: output)
        == ["emulator-5554", "usb-phone"]
    )
  }
}
