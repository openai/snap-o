import AppKit
import Sparkle
import SwiftUI

struct SnapOCommands: Commands {
  @Environment(\.openWindow)
  private var openWindow
  @FocusedValue(\.captureController)
  var captureController: CaptureWindowController?
  @FocusedValue(\.captureImage)
  var captureImage: NSImage?
  @FocusedValue(\.workspaceController)
  var workspaceController: WorkspaceLayoutController?
  @FocusedValue(\.toolHost)
  var toolHost: ToolHostModel?
  @FocusedValue(\.captureHistoryActions)
  var historyActions: CaptureHistoryActions?

  let settings: AppSettings
  let updaterController: SPUStandardUpdaterController

  var body: some Commands {
    CommandGroup(before: .windowSize) {
      Button("Capture History") { openWindow(id: "capture-history") }
        .keyboardShortcut("h", modifiers: [.command, .shift])
      Divider()
    }

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

      Button("Live Preview") {
        workspaceController?.revealCapture()
        Task { await captureController?.startLivePreview() }
      }
      .keyboardShortcut("l", modifiers: [.command, .shift])
      .disabled(captureController?.canSelectLivePreview != true)
    }

    CommandGroup(before: .saveItem) {
      Button("Save As…") {
        if let historyActions {
          historyActions.save()
          return
        }
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
      .disabled(captureController?.currentCapture?.media.url == nil && historyActions == nil)
      .keyboardShortcut("s")
    }
    if let captureController {
      CommandGroup(replacing: .pasteboard) {
        Button("Cut") {
          NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: nil)
        }
        .keyboardShortcut("x")

        Button("Copy") {
          if let captureImage {
            NSPasteboard.general.clearContents()
            if NSPasteboard.general.writeObjects([captureImage]) {
              captureController.imageCopied()
            }
            return
          }
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

        Button("Paste") {
          NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil)
        }
        .keyboardShortcut("v")

        Divider()

        Button("Select All") {
          NSApp.sendAction(#selector(NSResponder.selectAll(_:)), to: nil, from: nil)
        }
        .keyboardShortcut("a")
      }
      CommandGroup(replacing: .undoRedo) {}
    } else if let historyActions {
      CommandGroup(replacing: .pasteboard) {
        Button("Copy") { historyActions.copy?() }
          .keyboardShortcut("c")
          .disabled(historyActions.copy == nil)
      }
    }
    CommandMenu("Device") {
      let hasAlternativeMedia = historyActions?.canNavigate ?? captureController?.hasAlternativeMedia() ?? false

      Button("Previous Device") {
        if let historyActions {
          historyActions.previous()
          return
        }
        captureController?.selectPreviousMedia()
      }
      .keyboardShortcut("[")
      .disabled(!hasAlternativeMedia)

      Button("Next Device") {
        if let historyActions {
          historyActions.next()
          return
        }
        captureController?.selectNextMedia()
      }
      .keyboardShortcut("]")
      .disabled(!hasAlternativeMedia)
      Divider()
      @Bindable var settings = settings
      Picker("Start With", selection: $settings.startupCaptureMode) {
        ForEach(StartupCaptureMode.allCases) { mode in
          Text(mode.title).tag(mode)
        }
      }
      Toggle("Show Touches During Capture", isOn: $settings.showTouchesDuringCapture)
      Toggle("Record Screen as Bug Report", isOn: $settings.recordAsBugReport)
    }
    CommandMenu("Develop") {
      #if DEBUG
      Button("Show Web Inspector") { toolHost?.webContainer?.showWebInspector() }
        .disabled(toolHost?.isPageReady != true)
      Divider()
      #endif
      Button("Use Development Server…") { toolHost?.isDevelopmentServerPresented = true }
        .disabled(toolHost?.canConfigureDevelopmentServer != true)
      Button("Use Packaged Frontend") { toolHost?.useDevelopmentServer(nil) }
        .disabled(toolHost?.developmentURL == nil)
      if let url = toolHost?.developmentURL { Text(url.absoluteString) }
    }
    CommandGroup(after: .sidebar) {
      Button(workspaceController?.showsTool == true ? "Hide Tool Pane" : "Show Tool Pane") {
        workspaceController?.toggleTool()
      }
      .keyboardShortcut("i", modifiers: [.command, .option])
      .disabled(workspaceController?.canToggleTool != true)

      Button(workspaceController?.showsCapture == true ? "Hide Capture Pane" : "Show Capture Pane") {
        workspaceController?.toggleCapture()
      }
      .keyboardShortcut("c", modifiers: [.command, .option])
      .disabled(workspaceController?.canToggleCapture != true)
    }
  }
}
