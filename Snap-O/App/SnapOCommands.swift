import Sparkle
import SwiftUI

struct SnapOCommands: Commands {
  @FocusedObject var captureController: CaptureWindowController?

  @ObservedObject var settings: AppSettings
  private let adbService: ADBService
  private let networkInspectorController: NetworkInspectorWindowController

  private let updaterController: SPUStandardUpdaterController

  init(settings: AppSettings, adbService: ADBService, networkInspectorController: NetworkInspectorWindowController) {
    self.settings = settings
    self.adbService = adbService
    self.networkInspectorController = networkInspectorController
    // Initialize Sparkle updater controller; starts checks automatically
    updaterController = SPUStandardUpdaterController(
      startingUpdater: true,
      updaterDelegate: nil,
      userDriverDelegate: nil
    )
  }

  var body: some Commands {
    CommandGroup(after: .appInfo) {
      CheckForUpdatesView(updater: updaterController.updater)
    }
    CommandGroup(after: .newItem) {
      Divider()

      Button("New Screenshot") {
        Task { await captureController?.captureScreenshots() }
      }
      .keyboardShortcut("r")
      .disabled(captureController?.canCaptureNow != true)

      if captureController?.isRecording == true {
        Button("Stop Screen Recording") {
          Task { await captureController?.stopRecording() }
        }
        .keyboardShortcut(.escape, modifiers: [])
      } else {
        Button("Start Screen Recording") {
          Task { await captureController?.startRecording() }
        }
        .keyboardShortcut("r", modifiers: [.command, .shift])
        .disabled(captureController?.canStartRecordingNow != true)
      }

      if captureController?.isLivePreviewActive == true || captureController?.isStoppingLivePreview == true {
        Button("Stop Live Preview") {
          Task { await captureController?.stopLivePreview() }
        }
        .keyboardShortcut(.escape, modifiers: [])
        .disabled(captureController?.isStoppingLivePreview == true)
      } else {
        Button("Start Live Preview") {
          Task { await captureController?.startLivePreview() }
        }
        .keyboardShortcut("l", modifiers: [.command, .shift])
        .disabled(captureController?.canStartLivePreviewNow != true)
      }
    }

    CommandGroup(before: .saveItem) {
      Button("Save As…") {
        guard
          let media = captureController?.currentCapture?.media,
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
      .disabled(captureController?.currentCapture?.media.url == nil)
      .keyboardShortcut("s")
    }
    CommandGroup(replacing: .pasteboard) {
      Button("Copy") {
        captureController?.copyCurrentImage()
      }
      .keyboardShortcut("c")
      .disabled(captureController?.currentCapture?.media.isImage != true)
    }
    CommandGroup(replacing: .undoRedo) {}
    CommandMenu("Device") {
      let hasAlternativeMedia = captureController?.hasAlternativeMedia() ?? false

      Button("Previous Device") {
        captureController?.selectPreviousMedia()
      }
      .keyboardShortcut("[")
      .disabled(!hasAlternativeMedia)

      Button("Next Device") {
        captureController?.selectNextMedia()
      }
      .keyboardShortcut("]")
      .disabled(!hasAlternativeMedia)
      Divider()
      Toggle("Show Touches During Capture", isOn: $settings.showTouchesDuringCapture)
      Toggle("Record Screen as Bug Report", isOn: $settings.recordAsBugReport)
    }
    CommandMenu("Tools") {
      Button("Network Inspector") {
        networkInspectorController.showWindow()
      }
      Divider()
      Button("Set ADB path…") {
        Task { await adbService.promptForPath() }
      }
      if let url = ADBPathManager.lastKnownADBURL() {
        Text("Current: \(url.path)")
      }
    }
  }
}
