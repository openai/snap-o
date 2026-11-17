import AppKit
@testable import Snap_O
import SwiftUI
import Testing

@Suite("Device picker layout")
@MainActor
struct DevicePickerLayoutTests {
  @Test
  func namesGrowThePopoverUntilTheyTruncate() {
    let short = pickerSize(name: "Phone")
    let medium = pickerSize(name: "Foldable Emulator for UI Testing")
    let long = pickerSize(name: String(repeating: "Long device name ", count: 12))
    let longer = pickerSize(name: String(repeating: "Long device name ", count: 24))

    #expect(short.width < medium.width)
    #expect(medium.width < long.width)
    #expect(long.width == longer.width)
    #expect(short.height == long.height)
  }

  private func pickerSize(name: String) -> CGSize {
    let device = Device(id: "test", model: name, androidVersion: "16", vendorModel: nil, manufacturer: nil, avdName: nil)
    let picker = LiveDevicePicker(
      previews: [LivePreviewDevice(id: UUID(), device: device, display: nil)], selectedDeviceID: device.id,
      attachment: nil, loadSnapshot: { _ in throw CancellationError() }, serverName: { _ in nil }, selectDevice: { _ in }
    )
    return NSHostingController(rootView: picker).sizeThatFits(in: CGSize(width: 1000, height: 600))
  }
}
