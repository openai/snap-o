import Foundation
import Testing

struct DeviceFileCommandTests {
  @Test("shell output requires a successful final status")
  func checkedOutput() throws {
    #expect(try DeviceFileCommand.result("Success\n\nSNAPO_FILE_EXIT:0\r\n") == "Success")
    #expect(throws: (any Error).self) { try DeviceFileCommand.result("Success") }
    #expect(throws: (any Error).self) { try DeviceFileCommand.result("Permission denied\nSNAPO_FILE_EXIT:1\n") }
    #expect(DeviceFileCommand.quote("a'b;$(echo no)") == "'a'\\''b;$(echo no)'")
  }

  @Test("copy names preserve extensions and reject invalid paths")
  func copyNames() throws {
    #expect(try DeviceFileCommand.filename("photo.jpg", copy: 2) == "photo (2).jpg")
    #expect(try DeviceFileCommand.filename("README", copy: 1) == "README (1)")
    for name in ["", ".", "..", "../file", "line\nbreak"] {
      #expect(throws: (any Error).self) { try DeviceFileCommand.filename(name) }
    }
  }

  @Test("file-transfer policy checks only the target user's effective restrictions")
  func fileTransferPolicy() {
    let dump = """
    Users:
      UserInfo{0:Test:123} serialNo=0
        Restrictions:
          no_add_user
        Effective restrictions:
          no_usb_file_transfer
          no_add_user
        Account name: null
      UserInfo{10:Other:456} serialNo=10
        Effective restrictions:
          no_add_user
        Account name: null
    Guest restrictions:
      no_usb_file_transfer
    """
    #expect(DeviceFileCommand.blocksFileTransfers(dump, user: 0))
    #expect(!DeviceFileCommand.blocksFileTransfers(dump, user: 10))
    #expect(!DeviceFileCommand.blocksFileTransfers(dump, user: 11))
    #expect(!DeviceFileCommand.blocksFileTransfers("Permission denied", user: 0))
  }
}
