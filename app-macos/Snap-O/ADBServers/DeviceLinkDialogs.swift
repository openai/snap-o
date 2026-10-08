import AppKit
import SwiftUI

@MainActor
enum DeviceLinkDialogs {
  static func confirmEnable(server: DeviceLinkServer, serial: String) async -> Bool {
    await confirm(
      title: "Enable this ADB server and open the device?",
      message: "An external link requested a disabled server.\n\n\(details(server: server, serial: serial))",
      action: "Enable and Open"
    )
  }

  static func confirmAdd() async -> Bool {
    await confirm(
      title: "Add an ADB server for this device?",
      message: "An external link wants Snap-O to connect to a new SSH server."
        + "\n\nYou can review this server before adding it.",
      action: "Review Server"
    )
  }

  static func addServer(
    server: DeviceLinkServer, save: @escaping (RemoteADBServer) async throws -> Void
  ) async -> RemoteADBServer? {
    guard case .ssh(let destination, let port, let adbPort) = server else { return nil }
    let profile = RemoteADBServer(
      id: UUID(), connection: .ssh(SSHConfiguration(destination: destination, port: port, adbPort: adbPort))
    )
    let editor = DeviceLinkServerEditor(profile: profile, save: save)
    return await editor.present()
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

@MainActor
private final class DeviceLinkServerEditor: NSObject, NSWindowDelegate {
  private let window: NSPanel
  private var result: RemoteADBServer?
  private var continuation: CheckedContinuation<RemoteADBServer?, Never>?
  private var isSaving = false

  init(profile: RemoteADBServer, save: @escaping (RemoteADBServer) async throws -> Void) {
    window = NSPanel(
      contentRect: .zero, styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false
    )
    super.init()
    window.title = "Add ADB Server"
    window.titleVisibility = .hidden
    window.titlebarAppearsTransparent = true
    window.isReleasedWhenClosed = false
    window.delegate = self
    let onClose: () -> Void = { [weak self] in self?.close() }
    let view = ADBServerEditor(profile: profile, isNew: true, opensDevice: true, onClose: onClose) { [weak self] profile in
      guard let self else { throw CancellationError() }
      isSaving = true
      defer { isSaving = false }
      try await save(profile)
      result = profile
    }
    let content = NSHostingView(rootView: view)
    content.safeAreaRegions = []
    window.contentView = content
    window.setContentSize(content.fittingSize)
  }

  func present() async -> RemoteADBServer? {
    let result: RemoteADBServer? = await withCheckedContinuation { continuation in
      self.continuation = continuation
      let parent = NSApplication.shared.mainWindow ?? NSApplication.shared.windows.first {
        $0.isVisible && $0.canBecomeMain && !($0 is NSPanel)
      }
      if let parent {
        parent.beginSheet(window) { [self] _ in finish() }
      } else {
        window.center()
        window.makeKeyAndOrderFront(nil)
      }
    }
    return withExtendedLifetime(self) { result }
  }

  private func close() {
    if let parent = window.sheetParent { parent.endSheet(window) }
    window.close()
  }

  func windowShouldClose(_ sender: NSWindow) -> Bool {
    !isSaving
  }

  func windowWillClose(_ notification: Notification) {
    finish()
  }

  private func finish() {
    continuation?.resume(returning: result)
    continuation = nil
  }
}
