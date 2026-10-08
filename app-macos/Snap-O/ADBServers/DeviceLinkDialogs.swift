import AppKit

@MainActor
enum DeviceLinkDialogs {
  static func confirmEnable(server: DeviceLinkServer, serial: String) async -> Bool {
    await confirm(
      title: "Enable this ADB server and open the device?",
      message: "An external link requested a disabled server.\n\n\(details(server: server, serial: serial))",
      action: "Enable and Open"
    )
  }

  static func details(server: DeviceLinkServer, serial: String) -> String {
    guard case .ssh(let destination, let port, let adbPort) = server else { return "Device: \(serial)" }
    let sshPort = port.map(String.init) ?? "From SSH configuration"
    return "SSH server: \(destination)\nSSH port: \(sshPort)\nADB port: \(adbPort)\nDevice: \(serial)"
  }

  static func confirm(title: String, message: String, action: String) async -> Bool {
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = message
    alert.alertStyle = .warning
    alert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"
    alert.addButton(withTitle: action).keyEquivalent = ""
    alert.layout()
    alert.window.defaultButtonCell = nil
    NSApplication.shared.activate(ignoringOtherApps: true)
    if let window = NSApplication.shared.keyWindow, window.isVisible, window.attachedSheet == nil {
      return await alert.beginSheetModal(for: window) == .alertSecondButtonReturn
    }
    return alert.runModal() == .alertSecondButtonReturn
  }

  static func showError(_ error: Error) {
    let alert = NSAlert()
    alert.messageText = "Could not open device"
    alert.informativeText = error.localizedDescription
    alert.runModal()
  }
}
