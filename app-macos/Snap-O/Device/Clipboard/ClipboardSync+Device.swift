import AppKit

extension ClipboardSync {
  convenience init(
    settings: AppSettings, pasteboard: NSPasteboard = .general,
    maySynchronize: @escaping @MainActor () -> Bool = { true }
  ) {
    self.init(settings: settings, pasteboard: pasteboard, maySynchronize: maySynchronize) { target, synchronize in
      try Task.checkCancellation()
      let serial = target.serial
      if serial.hasPrefix("emulator-") {
        let emulator = AndroidHostClient()
        defer { emulator.close() }
        _ = try target.requireTransport(for: serial)
        let endpoint = try await emulator.clipboardEndpoint(serial: serial)
        try Task.checkCancellation()
        _ = try target.requireTransport(for: serial)
        let authentication = EmulatorClipboardAuthentication(endpoint: endpoint) {
          _ = try target.requireTransport(for: serial)
          let endpoint = try await emulator.clipboardEndpoint(serial: serial)
          try Task.checkCancellation()
          _ = try target.requireTransport(for: serial)
          return endpoint
        }
        try await EmulatorClipboardTransport.connect(target: target, endpoint: endpoint, authentication: authentication) { transport in
          try await synchronize(transport)
        }
      } else {
        try await DeviceClipboardTransport.connect(serial: serial, adb: ADBClient().bound(to: target)) { transport in
          try await synchronize(transport)
        }
      }
    }
  }
}
