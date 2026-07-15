import AppKit
import Sparkle
import SwiftUI

struct SnapOCommands: Commands {
  @Environment(\.openWindow)
  private var openWindow
  @FocusedValue(\.captureController)
  var captureController: CaptureWindowController?
  @FocusedValue(\.workspaceController)
  var workspaceController: WorkspaceLayoutController?

  let settings: AppSettings
  let adbService: ADBService
  let updaterController: SPUStandardUpdaterController

  var body: some Commands {
    CommandGroup(replacing: .newItem) {
      Button("New Window") {
        let workspace = workspaceController?.snapshot ?? .persisted()
        openWindow(
          id: WorkspaceWindowID.main,
          value: WorkspaceWindowConfiguration(workspace: workspace)
        )
      }
      .keyboardShortcut("n")
    }

    CommandGroup(after: .appInfo) {
      CheckForUpdatesView(updater: updaterController.updater)
    }
    CommandGroup(after: .newItem) {
      Divider()

      Button("New Screenshot") {
        workspaceController?.revealCapture()
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
          workspaceController?.revealCapture()
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
          workspaceController?.revealCapture()
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
    if let captureController {
      CommandGroup(replacing: .pasteboard) {
        Button("Copy") {
          let copiedFocusedContent = NSApp.sendAction(
            #selector(NSText.copy(_:)),
            to: nil,
            from: nil
          )
          if !copiedFocusedContent {
            captureController.copyCurrentImage()
          }
        }
        .keyboardShortcut("c")

        Divider()

        Button("Select All") {
          NSApp.sendAction(#selector(NSResponder.selectAll(_:)), to: nil, from: nil)
        }
        .keyboardShortcut("a")
      }
      CommandGroup(replacing: .undoRedo) {}
    }
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
      @Bindable var settings = settings
      Toggle("Show Touches During Capture", isOn: $settings.showTouchesDuringCapture)
      Toggle("Record Screen as Bug Report", isOn: $settings.recordAsBugReport)
    }
    CommandMenu("Tools") {
      Button(workspaceController?.showsNetwork == true ? "Hide Network Inspector" : "Show Network Inspector") {
        workspaceController?.toggleNetwork()
      }
      .keyboardShortcut("i", modifiers: [.command, .option])
      .disabled(workspaceController?.canToggleNetwork != true)

      Button(workspaceController?.showsCapture == true ? "Hide Capture" : "Show Capture") {
        workspaceController?.toggleCapture()
      }
      .keyboardShortcut("c", modifiers: [.command, .option])
      .disabled(workspaceController?.canToggleCapture != true)

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
