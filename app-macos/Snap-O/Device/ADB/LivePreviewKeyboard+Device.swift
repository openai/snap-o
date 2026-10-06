import AppKit

extension LivePreviewKeyboard {
  convenience init(device: Device, pasteboard: NSPasteboard = .general) {
    self.init(deviceID: device.id, target: device.connection, pasteboard: pasteboard) { _ in
      let target = try device.requireConnection()
      return try await DeviceKeyboardTransport.connect(serial: device.id, adb: ADBClient().bound(to: target))
    }
  }
}
