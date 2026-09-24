import SwiftUI

struct DeviceControlsView: View {
  @Environment(AppSettings.self)
  private var settings
  let serial: String
  var placement: DeviceControlsPlacement = .below
  let connection: LivePreviewConnection?
  let sendKey: (String) async throws -> Void
  let didChangeDisplay: () -> Void
  @State private var pendingKey: String?
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
      if serial.hasPrefix("emulator-") {
        EmulatorControlsView(serial: serial, isVertical: placement == .left, didChangeDisplay: didChangeDisplay)
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
    .task(id: pendingKey) {
      guard let pendingKey else { return }
      do {
        try await sendKey(pendingKey)
      } catch {
        if !Task.isCancelled { inputFailed = true }
      }
      if !Task.isCancelled, self.pendingKey == pendingKey { self.pendingKey = nil }
    }
    .task(id: pendingRotation) {
      guard let pendingRotation else { return }
      do {
        try await connection?.rotateDevice(deviceID: serial, left: pendingRotation == .rotateLeft)
      } catch {
        if !Task.isCancelled { inputFailed = true }
      }
      if !Task.isCancelled { self.pendingRotation = nil }
    }
    .alert("Couldn’t Send Device Input", isPresented: $inputFailed) {
      Button("OK", role: .cancel) {}
    } message: {
      Text("The device did not respond. Check its connection and try again.")
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

  private func key(_ command: LivePreviewDeviceCommand, symbol: String) -> some View {
    Button { pendingKey = command.keyCode } label: {
      icon(symbol).foregroundStyle(.primary)
    }
    .help(command.help)
    .accessibilityLabel(command.title)
    .disabled(pendingKey != nil)
  }

  private func rotationButton(_ command: LivePreviewDeviceCommand, symbol: String) -> some View {
    Button { pendingRotation = command } label: {
      icon(symbol).foregroundStyle(.primary).offset(y: -2)
    }
    .help(command.help)
    .accessibilityLabel(command.title)
    .disabled(connection == nil || pendingRotation != nil)
  }

  private var keyboardButton: some View {
    @Bindable var settings = settings
    return Toggle(isOn: $settings.keyboardInput) {
      icon("keyboard")
        .foregroundStyle(settings.keyboardInput ? Color.accentColor : Color.secondary)
    }
    .toggleStyle(.button)
    .help(settings.keyboardInput ? "Keyboard input: On. Click the preview to type." : "Keyboard input: Off")
    .accessibilityLabel("Keyboard input")
    .accessibilityValue(settings.keyboardInput ? "On" : "Off")
  }

  private var clipboardButton: some View {
    @Bindable var settings = settings
    return Toggle(isOn: $settings.syncClipboard) {
      icon("clipboard")
        .foregroundStyle(settings.syncClipboard ? Color.accentColor : Color.secondary)
    }
    .toggleStyle(.button)
    .help(!settings.syncClipboard ? "Sync clipboard: Off" : connection?.clipboard?.isUnavailable == true
      ? "Sync clipboard: Connection unavailable. Retrying…" : "Sync clipboard: On")
    .accessibilityLabel("Sync clipboard")
    .accessibilityValue(settings.syncClipboard ? "On" : "Off")
  }

  private func icon(_ symbol: String) -> some View {
    Image(systemName: symbol)
      .font(.system(size: 15, weight: .regular))
      .frame(width: 32, height: 36)
      .contentShape(Rectangle())
  }
}
