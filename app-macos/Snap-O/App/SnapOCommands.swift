import AppKit
import Sparkle
import SwiftUI

struct SnapOCommands: Commands {
  @Environment(\.openWindow)
  private var openWindow
  @FocusedValue(\.captureController)
  var captureController: CapturePaneSession?
  @FocusedValue(\.captureImage)
  var captureImage: NSImage?
  @FocusedValue(\.workspaceController)
  var workspaceController: WorkspaceLayoutController?
  @FocusedValue(\.toolHost)
  var toolHost: ToolHostModel?
  @FocusedValue(\.captureHistoryActions)
  var historyActions: CaptureHistoryActions?

  @FocusedValue(\.livePreviewCommands)
  private var livePreviewCommands: LivePreviewCommandActions?

  let history: CaptureHistory
  let settings: AppSettings
  let updaterController: SPUStandardUpdaterController

  var body: some Commands {
    // CommandsBuilder needs a declaration for this diagnostic side effect.
    // swiftlint:disable:next redundant_discardable_let
    let _ = CommandDiagnostics.shared.focusedWorkspaceEvaluated(workspaceController)
    CommandGroup(before: .windowSize) {
      Button("Device Manager") { openWindow(id: "device-manager") }
        .keyboardShortcut("m", modifiers: [.command, .shift])
      Button("Capture History") { openWindow(id: "capture-history") }
        .keyboardShortcut("y")
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
        captureController?.launch(.screenshot)
      }
      .keyboardShortcut("s", modifiers: [.command, .shift])
      .disabled(captureController?.canCaptureNow != true)

      if captureController?.isRecording == true {
        Button("Stop Screen Recording") {
          captureController?.launch(.stopRecording)
        }
        .keyboardShortcut("v", modifiers: [.command, .shift])
      } else {
        Button("Start Screen Recording") {
          workspaceController?.revealCapture()
          captureController?.launch(.startRecording)
        }
        .keyboardShortcut("v", modifiers: [.command, .shift])
        .disabled(captureController?.canStartRecordingNow != true)
      }

      Button("Live Preview") {
        workspaceController?.revealCapture()
        captureController?.launch(.livePreview)
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
          let controller = captureController,
          let review = controller.review,
          let capture = review.currentCapture,
          capture.media.url != nil,
          let saveKind = capture.media.saveKind
        else { return }
        let savePanel = NSSavePanel()
        savePanel.canCreateDirectories = true
        savePanel.title = "Save As"
        savePanel.nameFieldStringValue = FileStore.exportFilename(
          capturedAt: capture.media.capturedAt, kind: saveKind, name: history.name(for: capture.id)
        )
        savePanel.directoryURL = SaveLocation.defaultDirectory(for: saveKind)

        if savePanel.runModal() == .OK, let dest = savePanel.url {
          Task {
            do {
              try await review.exportSelected(to: dest)
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
      }
      .disabled(historyActions == nil && (
        captureController?.review?.currentCapture?.media.url == nil || captureController?.review?.isSaving == true
      ))
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
      Button("Device Manager…") { openWindow(id: "device-manager") }
      Button("ADB Servers…") { openWindow(id: "adb-servers") }
      Divider()
      ForEach(LivePreviewDeviceCommand.allCases, id: \.self) { command in
        Button(command.title) {
          livePreviewCommands?.perform(command)
        }
        .keyboardShortcut(command.shortcut, modifiers: command.modifiers)
        .disabled(livePreviewCommands?.supports(command) != true)
      }
      Divider()
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
      Picker("Control Bar", selection: $settings.deviceControlsPlacement) {
        ForEach(DeviceControlsPlacement.allCases) { placement in
          Text(placement.title).tag(placement)
        }
      }
      Divider()
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
      Button("Use Default") { toolHost?.useDevelopmentServer(nil) }
        .disabled(toolHost?.developmentURL == nil)
        .help("Use the inspector bundled with the Android app.")
      if let url = toolHost?.developmentURL { Text(url.absoluteString) }
    }
    CommandGroup(after: .sidebar) {
      Button(workspaceController?.showsTool == true ? "Hide Tool Pane" : "Show Tool Pane") {
        CommandDiagnostics.shared.paneAction("toggle-tool", source: "menu", workspace: workspaceController)
        workspaceController?.toggleTool()
      }
      .keyboardShortcut("i", modifiers: [.command, .option])
      .disabled(workspaceController?.canToggleTool != true)

      Button(workspaceController?.showsCapture == true ? "Hide Capture Pane" : "Show Capture Pane") {
        CommandDiagnostics.shared.paneAction("toggle-capture", source: "menu", workspace: workspaceController)
        workspaceController?.toggleCapture()
      }
      .keyboardShortcut("c", modifiers: [.command, .option])
      .disabled(workspaceController?.canToggleCapture != true)
    }
  }
}
