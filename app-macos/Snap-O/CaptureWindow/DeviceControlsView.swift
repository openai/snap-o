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
  @State private var inputFailed = false

  var body: some View {
    stack(spacing: 6) {
      stack(spacing: 4) {
        key("Back", symbol: "chevron.left", code: "KEYCODE_BACK")
        key("Home", symbol: "circle", code: "KEYCODE_HOME")
        key("Recents", symbol: "square", code: "KEYCODE_APP_SWITCH")
      }
      if serial.hasPrefix("emulator-") {
        divider
        EmulatorControlsView(serial: serial, isVertical: placement == .left, didChangeDisplay: didChangeDisplay)
      }
      divider
      stack(spacing: 4) {
        key("Volume Down", symbol: "speaker.minus", code: "KEYCODE_VOLUME_DOWN")
        key("Volume Up", symbol: "speaker.plus", code: "KEYCODE_VOLUME_UP")
        key("Power/Wake", symbol: "power", code: "KEYCODE_POWER")
      }
      if serial.hasPrefix("emulator-") {
        divider
        clipboardButton
      }
    }
    .padding(8)
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
        ForEach(DeviceControlsPlacement.allCases) { placement in
          Text(placement.title).tag(placement)
        }
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
      if !Task.isCancelled { self.pendingKey = nil }
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

  private func key(_ title: String, symbol: String, code: String) -> some View {
    Button { pendingKey = code } label: {
      icon(symbol).foregroundStyle(.primary)
    }
    .help(title)
    .accessibilityLabel(title)
    .disabled(pendingKey != nil)
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
      .resizable()
      .scaledToFit()
      .frame(width: 15, height: 15)
      .frame(width: 32, height: 36)
      .contentShape(Rectangle())
  }
}
