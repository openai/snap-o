import SwiftUI

struct LivePreviewToolbarButtonStyle: ButtonStyle {
  var isOn = false
  var isHeld = false
  @Environment(\.isEnabled)
  private var isEnabled
  @State private var isHovered = false

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.system(size: 15, weight: .regular))
      .foregroundStyle(isOn ? Color.accentColor : Color.primary)
      .frame(width: 32, height: 32)
      .background {
        RoundedRectangle(cornerRadius: 6)
          .fill(Color.primary.opacity(isEnabled ? (configuration.isPressed || isHeld ? 0.14 : isHovered ? 0.07 : 0) : 0))
      }
      .contentShape(Rectangle())
      .opacity(isEnabled ? 1 : 0.4)
      .onHover { isHovered = $0 }
  }
}

struct LivePreviewHeldKeyButton: View {
  let title: String
  let symbol: String
  let attachment: LivePreviewAttachment?
  let code: UInt32
  @GestureState private var isPressed = false
  @State private var source = UUID()
  @State private var activePress: (attachment: LivePreviewAttachment, code: UInt32)?

  var body: some View {
    Button { attachment?.send(.key(code: code)) } label: {
      Image(systemName: symbol)
    }
    .buttonStyle(LivePreviewToolbarButtonStyle(isHeld: isPressed))
    // The gesture consumes mouse clicks; the Button action handles keyboard and accessibility activation.
    .highPriorityGesture(
      DragGesture(minimumDistance: 0)
        .updating($isPressed) { _, pressed, _ in pressed = true }
        .onChanged { _ in
          guard activePress == nil, let attachment, attachment.acceptsInput else { return }
          activePress = (attachment, code)
          attachment.setKeyPressed(true, code: code, source: source)
        }
        .onEnded { _ in release() }
    )
    // Gesture state also resets on cancellation, when onEnded isn't called.
    .onChange(of: isPressed) { _, pressed in
      if !pressed { release() }
    }
    .onDisappear { release() }
    .accessibilityLabel(title)
    .disabled(attachment?.acceptsInput != true)
  }

  private func release() {
    guard let press = activePress else { return }
    activePress = nil
    press.attachment.setKeyPressed(false, code: press.code, source: source)
  }
}
