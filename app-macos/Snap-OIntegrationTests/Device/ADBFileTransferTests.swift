import Foundation
@testable import Snap_O
import Testing

@Suite("Device file transfers")
struct ADBFileTransferTests {
  @Test("APK drops prompt once and keep mixed files together")
  @MainActor
  func apkPrompt() {
    let device = Device(
      id: "synthetic", model: "Test phone", androidVersion: "16", vendorModel: nil, manufacturer: nil, avdName: nil,
      connection: DeviceTarget(serial: "synthetic", transportID: "1")
    )
    let model = DeviceFileDrop(device: device)
    let apk = URL(fileURLWithPath: "/tmp/synthetic.apk")
    let text = URL(fileURLWithPath: "/tmp/synthetic.txt")
    #expect(model.receive([apk, text]))
    #expect(!model.canAcceptDrop)
    #expect(model.asksToInstall)
    #expect(model.pendingFiles == [apk, text])
    #expect(model.installMessage == "1 other file will copy to Downloads.")
    model.cancel()
    #expect(model.canAcceptDrop)
    #expect(model.pendingFiles.isEmpty)
  }
}
