import Observation
import SwiftUI

struct SnapOCommands: Commands {
  @FocusedValue(\.captureController)
  var controller: CaptureController?

  @Bindable var settings: AppSettings
  private let adbService: ADBService

  init(settings: AppSettings, adbService: ADBService) {
    self.settings = settings
    self.adbService = adbService
  }

  var body: some Commands {
    CommandGroup(after: .newItem) {
      Divider()

      Button("New Screenshot") {
        Task { await controller?.refreshPreview() }
      }
      .keyboardShortcut("r", modifiers: [.command])
      .disabled(controller?.canCapture != true)

      if controller?.isRecording == true {
        Button("Stop Screen Recording") {
          Task { await controller?.stopRecording() }
        }
        .keyboardShortcut(.escape, modifiers: [])
      } else {
        Button("Start Screen Recording") {
          Task { await controller?.startRecording() }
        }
        .keyboardShortcut("r", modifiers: [.command, .shift])
        .disabled(controller?.canStartRecordingNow != true)
      }

      if controller?.currentMedia?.isLivePreview == true {
        Button("Stop Live Preview") {
          Task { await controller?.stopLivePreview(withRefresh: true) }
        }
        .keyboardShortcut(.escape, modifiers: [])
      } else {
        Button("Start Live Preview") {
          Task { await controller?.startLivePreview() }
        }
        .keyboardShortcut("l", modifiers: [.command, .shift])
        .disabled(controller?.canStartLivePreviewNow != true)
      }
    }

    CommandGroup(before: .saveItem) {
      Button("Save As…") {
        guard
          let media = controller?.currentMedia,
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
      .disabled(controller?.currentMedia?.url == nil)
      .keyboardShortcut("s", modifiers: [.command])
    }
    CommandGroup(replacing: .pasteboard) {
      Button("Copy") {
        controller?.copy()
      }
      .keyboardShortcut("c", modifiers: [.command])
      .disabled(controller?.currentMedia?.isImage != true)
    }
    CommandGroup(replacing: .undoRedo) {}
    CommandMenu("Device") {
      Button("Previous Device") {
        controller?.selectPreviousDevice()
      }
      .keyboardShortcut(.upArrow, modifiers: [.command])
      .disabled(
        !(controller?.canCapture ?? false) ||
          (controller?.devices.available.count ?? 0) < 2
      )
      Button("Next Device") {
        controller?.selectNextDevice()
      }
      .keyboardShortcut(.downArrow, modifiers: [.command])
      .disabled(
        controller?.canCapture != true ||
          (controller?.devices.available.count ?? 0) < 2
      )
      Divider()
      Toggle("Show Touches During Capture", isOn: $settings.showTouchesDuringCapture)
    }
    CommandMenu("ADB") {
      Button("Set ADB path…") {
        Task { await adbService.promptForPath() }
      }
      if let url = ADBPathManager.lastKnownADBURL() {
        Text("Current: \(url.path)")
      }
    }
  }
}
