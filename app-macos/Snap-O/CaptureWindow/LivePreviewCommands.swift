import SwiftUI

enum LivePreviewDeviceCommand: CaseIterable {
  case back, home, recents, power, volumeUp, volumeDown, rotateLeft, rotateRight

  var title: String {
    switch self {
    case .back: "Back"
    case .home: "Home"
    case .recents: "Recents"
    case .power: "Power/Wake"
    case .volumeUp: "Volume Up"
    case .volumeDown: "Volume Down"
    case .rotateLeft: "Rotate Left"
    case .rotateRight: "Rotate Right"
    }
  }

  var shortcut: KeyEquivalent {
    switch self {
    case .back: "b"
    case .home: "h"
    case .recents: "w"
    case .power: "p"
    case .volumeUp: "u"
    case .volumeDown: "d"
    case .rotateLeft: "l"
    case .rotateRight: "r"
    }
  }

  var modifiers: EventModifiers {
    !isRotation ? [.command, .shift] : .command
  }

  var help: String {
    let modifierSymbols = !isRotation ? "⇧⌘" : "⌘"
    return "\(title) (\(modifierSymbols)\(String(shortcut.character).uppercased()))"
  }

  var keyCode: String? {
    switch self {
    case .back: "KEYCODE_BACK"
    case .home: "KEYCODE_HOME"
    case .recents: "KEYCODE_APP_SWITCH"
    case .power: "KEYCODE_POWER"
    case .volumeUp: "KEYCODE_VOLUME_UP"
    case .volumeDown: "KEYCODE_VOLUME_DOWN"
    case .rotateLeft, .rotateRight: nil
    }
  }

  var isRotation: Bool {
    self == .rotateLeft || self == .rotateRight
  }
}

struct LivePreviewCommandActions {
  let canRotate: Bool
  let isBusy: Bool
  let perform: (LivePreviewDeviceCommand) -> Void

  func supports(_ command: LivePreviewDeviceCommand) -> Bool {
    !isBusy && (!command.isRotation || canRotate)
  }
}

private struct LivePreviewCommandsKey: FocusedValueKey {
  typealias Value = LivePreviewCommandActions
}

extension FocusedValues {
  var livePreviewCommands: LivePreviewCommandActions? {
    get { self[LivePreviewCommandsKey.self] }
    set { self[LivePreviewCommandsKey.self] = newValue }
  }
}

/// Keeps menu actions available independently of the floating control bar.
struct LivePreviewCommandHandler: View {
  let controller: CaptureWindowController
  let deviceID: String
  @State private var pendingCommand: LivePreviewDeviceCommand?
  @State private var failure: String?

  var body: some View {
    Color.clear
      .allowsHitTesting(false)
      .focusedSceneValue(\.livePreviewCommands, LivePreviewCommandActions(
        canRotate: true,
        isBusy: pendingCommand != nil
      ) { if pendingCommand == nil { pendingCommand = $0 } })
      .task(id: pendingCommand) {
        guard let command = pendingCommand else { return }
        do {
          if let key = command.keyCode {
            try await controller.sendLivePreviewKey(key, deviceID: deviceID)
          } else if command.isRotation {
            try await controller.livePreviewConnection(for: deviceID)?.rotateDevice(
              deviceID: deviceID, left: command == .rotateLeft
            )
          }
        } catch {
          if !Task.isCancelled { failure = error.localizedDescription }
        }
        if !Task.isCancelled { pendingCommand = nil }
      }
      .alert("Couldn’t Control Device", isPresented: Binding(
        get: { failure != nil },
        set: { if !$0 { failure = nil } }
      )) {
        Button("OK", role: .cancel) {}
      } message: {
        Text(failure ?? "")
      }
  }
}
