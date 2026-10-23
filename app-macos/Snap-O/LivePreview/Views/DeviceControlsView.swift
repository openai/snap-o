import SwiftUI

struct DeviceControlsView: View {
  @Environment(AppSettings.self)
  private var settings
  var placement: DeviceControlsPlacement = .below
  let attachment: LivePreviewAttachment?
  let didChangeDisplay: @MainActor () -> Void
  @State private var pendingRotation: LivePreviewDeviceCommand?
  @State private var inputFailed = false

  var body: some View {
    stack(spacing: 6) {
      stack(spacing: 4) {
        key(.back, symbol: "chevron.left")
        key(.home, symbol: "circle")
        key(.recents, symbol: "square")
      }
      divider
      stack(spacing: 4) {
        rotationButton(.rotateLeft, symbol: "rotate.left")
        rotationButton(.rotateRight, symbol: "rotate.right")
      }
      if let controls = attachment?.emulatorControls {
        EmulatorControlsView(controller: controls, isVertical: placement == .left, didChangeDisplay: didChangeDisplay)
          .id(controls.target.id)
      }
      divider
      stack(spacing: 4) {
        if placement == .left {
          key(.volumeUp, symbol: "speaker.plus")
          key(.volumeDown, symbol: "speaker.minus")
        } else {
          key(.volumeDown, symbol: "speaker.minus")
          key(.volumeUp, symbol: "speaker.plus")
        }
        key(.power, symbol: "power")
      }
      divider
      clipboardButton
      keyboardButton
    }
    .padding(placement == .left ? .vertical : .horizontal, 8)
    .padding(placement == .left ? .horizontal : .vertical, 6.5)
    .fixedSize()
    .buttonStyle(.plain)
    .controlSize(.regular)
    .background(Color(nsColor: .windowBackgroundColor), in: panelShape)
    .overlay {
      panelShape
        .strokeBorder(.separator, lineWidth: 1)
        .allowsHitTesting(false)
    }
    .contextMenu {
      @Bindable var settings = settings
      Picker("Position", selection: $settings.deviceControlsPlacement) {
        ForEach(DeviceControlsPlacement.allCases.filter { $0 != .hidden }) { placement in
          Text(placement.title).tag(placement)
        }
      }
      Divider()
      Button("Hide") {
        settings.deviceControlsPlacement = .hidden
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Device controls")
    .task(id: pendingRotation) {
      guard let pendingRotation else { return }
      do {
        try await attachment?.rotate(left: pendingRotation == .rotateLeft)
      } catch {
        if !Task.isCancelled { inputFailed = true }
      }
      if !Task.isCancelled { self.pendingRotation = nil }
    }
    .alert("Couldn’t Send Device Input", isPresented: $inputFailed) {
      Button("OK", role: .cancel) {}
    } message: {
      Text("The device did not respond. Check its attachment and try again.")
    }
  }

  private func stack(spacing: CGFloat, @ViewBuilder content: () -> some View) -> some View {
    let layout = placement == .left ? AnyLayout(VStackLayout(spacing: spacing)) : AnyLayout(HStackLayout(spacing: spacing))
    return layout { content() }
  }

  private var panelShape: RoundedRectangle {
    RoundedRectangle(cornerRadius: 10)
  }

  private var divider: some View {
    Rectangle()
      .fill(.separator)
      .frame(width: placement == .left ? 24 : 1, height: placement == .left ? 1 : 24)
  }

  @ViewBuilder
  private func key(_ command: LivePreviewDeviceCommand, symbol: String) -> some View {
    if let code = command.androidKeyCode {
      LivePreviewHeldKeyButton(title: command.title, symbol: symbol, attachment: attachment, code: code)
        .help("\(command.help). Hold to long-press.")
    }
  }

  private func rotationButton(_ command: LivePreviewDeviceCommand, symbol: String) -> some View {
    Button { pendingRotation = command } label: {
      Image(systemName: symbol)
    }
    .buttonStyle(LivePreviewToolbarButtonStyle())
    .help(command.help)
    .accessibilityLabel(command.title)
    .disabled(attachment == nil || pendingRotation != nil)
  }

  private var keyboardButton: some View {
    @Bindable var settings = settings
    return Toggle(isOn: $settings.keyboardInput) {
      Image(systemName: "keyboard")
    }
    .toggleStyle(.button)
    .buttonStyle(LivePreviewToolbarButtonStyle(isOn: settings.keyboardInput))
    .help(settings.keyboardInput ? "Keyboard input: On. Click the preview to type." : "Keyboard input: Off")
    .accessibilityLabel("Keyboard input")
  }

  private var clipboardButton: some View {
    @Bindable var settings = settings
    return Toggle(isOn: $settings.syncClipboard) {
      Image(systemName: "clipboard")
    }
    .toggleStyle(.button)
    .buttonStyle(LivePreviewToolbarButtonStyle(isOn: settings.syncClipboard))
    .help(!settings.syncClipboard ? "Sync clipboard: Off" : attachment?.preview?.clipboardUnavailable == true
      ? "Sync clipboard: Connection unavailable. Retrying" : "Sync clipboard: On")
    .accessibilityLabel("Sync clipboard")
  }
}
