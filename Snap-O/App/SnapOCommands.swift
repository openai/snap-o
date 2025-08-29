import SwiftUI

struct SnapOCommands: Commands {
  @FocusedValue(\.captureWindow)
  var coordinator: CaptureWindowCoordinator?

  @Bindable var settings: AppSettings

  init(settings: AppSettings) {
    self.settings = settings
  }

  var body: some Commands {
    CommandGroup(after: .newItem) {
      Divider()

      Button("New Screenshot") {
        Task { await coordinator?.refreshPreview() }
      }
      .keyboardShortcut("r", modifiers: [.command])
      .disabled(coordinator?.canCapture != true)

      if coordinator?.captureVM.isRecording == true {
        Button("Stop Screen Recording") {
          Task { await coordinator?.stopRecording() }
        }
        .keyboardShortcut(.escape, modifiers: [])
      } else {
        Button("Start Screen Recording") {
          Task { await coordinator?.startRecording() }
        }
        .keyboardShortcut("r", modifiers: [.command, .shift])
        .disabled(coordinator?.canStartRecordingNow != true)
      }

      if coordinator?.captureVM.currentMedia?.isLivePreview == true {
        Button("Stop Live Preview") {
          coordinator?.stopLivePreview(refreshPreview: true)
        }
        .keyboardShortcut(.escape, modifiers: [])
      } else {
        Button("Start Live Preview") {
          Task { await coordinator?.startLivePreview() }
        }
        .keyboardShortcut("l", modifiers: [.command, .shift])
        .disabled(coordinator?.canStartLivePreviewNow != true)
      }
    }

    CommandGroup(before: .saveItem) {
      Button("Save As…") {
        guard
          let media = coordinator?.captureVM.currentMedia,
          let url = media.url,
          let saveKind = media.saveKind
        else { return }
        let savePanel = NSSavePanel()
        savePanel.canCreateDirectories = true
        savePanel.title = "Save As"
        savePanel.nameFieldStringValue = url.lastPathComponent
        savePanel.directoryURL = SaveLocation.defaultDirectory(for: saveKind)

        if savePanel.runModal() == .OK, let dest = savePanel.url {
          do {
            try FileManager.default.copyItem(at: url, to: dest)
            SaveLocation.setLastDirectoryURL(dest.deletingLastPathComponent(), for: saveKind)
          } catch {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Unable to Save File"
            alert.informativeText = error.localizedDescription
            alert.runModal()
          }
        }
      }
      .disabled(coordinator?.captureVM.currentMedia?.url == nil)
      .keyboardShortcut("s", modifiers: [.command])
    }
    CommandGroup(replacing: .pasteboard) {
      Button("Copy") {
        coordinator?.captureVM.copy()
      }
      .keyboardShortcut("c", modifiers: [.command])
      .disabled(coordinator?.captureVM.currentMedia?.isImage != true)
    }
    CommandGroup(replacing: .undoRedo) {}
    CommandMenu("Device") {
      Button("Previous Device") {
        coordinator?.selectPreviousDevice()
      }
      .keyboardShortcut(.upArrow, modifiers: [.command])
      .disabled(
        !(coordinator?.canCapture ?? false) ||
          (coordinator?.devices.count ?? 0) < 2
      )
      Button("Next Device") {
        coordinator?.selectNextDevice()
      }
      .keyboardShortcut(.downArrow, modifiers: [.command])
      .disabled(
        coordinator?.canCapture != true ||
          (coordinator?.devices.count ?? 0) < 2
      )
      Divider()
      Toggle("Show Touches During Capture", isOn: $settings.showTouchesDuringCapture)
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
