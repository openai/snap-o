import SwiftUI

struct SnapOCommands: Commands {
  @FocusedValue(\.captureWindow)
  var coordinator: CaptureWindowCoordinator?

  var body: some Commands {
    CommandGroup(after: .newItem) {
      Divider()
      Button("New Screenshot") {
        Task { await coordinator?.refreshPreview() }
      }
      .keyboardShortcut("r", modifiers: [.command])
      .disabled(coordinator?.canCapture != true)

      if coordinator?.captureVM.isRecording != true {
        Button("Start Screen Recording") {
          Task { await coordinator?.startRecording() }
        }
        .keyboardShortcut("r", modifiers: [.command, .shift])
        .disabled(coordinator?.canStartRecordingNow != true)
      } else if coordinator?.captureVM.isRecording == true {
        Button("Stop Screen Recording") {
          Task { await coordinator?.stopRecording() }
        }
        .keyboardShortcut(.escape, modifiers: [])
      }
    }
    CommandGroup(before: .saveItem) {
      Button("Save As…") {
        guard let media = coordinator?.captureVM.currentMedia else { return }
        let savePanel = NSSavePanel()
        savePanel.canCreateDirectories = true
        savePanel.title = "Save As"
        savePanel.nameFieldStringValue = media.url.lastPathComponent
        savePanel.directoryURL = SaveLocation.defaultDirectory(for: media.kind)

        if savePanel.runModal() == .OK, let dest = savePanel.url {
          do {
            try FileManager.default.copyItem(at: media.url, to: dest)
            SaveLocation.setLastDirectoryURL(dest.deletingLastPathComponent(), for: media.kind)
          } catch {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Unable to Save File"
            alert.informativeText = error.localizedDescription
            alert.runModal()
          }
        }
      }
      .disabled(coordinator?.captureVM.currentMedia == nil)
      .keyboardShortcut("s", modifiers: [.command])
    }
    CommandGroup(replacing: .pasteboard) {
      Button("Copy") {
        coordinator?.captureVM.copy()
      }
      .keyboardShortcut("c", modifiers: [.command])
      .disabled(coordinator?.captureVM.currentMedia?.kind != .image)
    }
    CommandGroup(replacing: .undoRedo) {}
    CommandMenu("Device") {
      Button("Previous Device") {
        coordinator?.deviceVM.selectPreviousDevice()
      }
      .keyboardShortcut(.upArrow, modifiers: [.command])
      .disabled(
        !(coordinator?.canCapture ?? false) ||
          (coordinator?.deviceVM.devices.count ?? 0) < 2
      )
      Button("Next Device") {
        coordinator?.deviceVM.selectNextDevice()
      }
      .keyboardShortcut(.downArrow, modifiers: [.command])
      .disabled(
        coordinator?.canCapture != true ||
          (coordinator?.deviceVM.devices.count ?? 0) < 2
      )
    }
    CommandMenu("ADB") {
      Button("Set ADB path…") {
        Task { await coordinator?.promptForADBPath() }
      }
      if let url = ADBPathManager.lastKnownADBURL() {
        Text("Current: \(url.path)")
      }
    }
  }
}
