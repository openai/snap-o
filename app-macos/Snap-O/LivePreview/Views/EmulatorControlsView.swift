import SwiftUI

struct EmulatorControlsView: View {
  let controller: EmulatorControlsController
  var isVertical = false
  let didChangeDisplay: @MainActor () -> Void
  @State private var viewID = UUID()

  var body: some View {
    let stack = isVertical ? AnyLayout(VStackLayout(spacing: 4)) : AnyLayout(HStackLayout(spacing: 4))
    stack {
      if let controls = controller.controls {
        menu("Display Mode", actions: controls.displayModes.map(\.action), selected: controls.currentDisplayMode, fallbackSymbol: "display")
        menu("Posture", actions: controls.postures, selected: controls.currentPosture, fallbackSymbol: "questionmark.square")
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Emulator controls")
    .onAppear { controller.appear(viewID: viewID) }
    .onDisappear { controller.disappear(viewID: viewID) }
    .alert(controller.failure?.action.failureTitle ?? "Emulator Controls", isPresented: Binding(
      get: { controller.failure != nil },
      set: { if !$0 { controller.dismissFailure() } }
    ), presenting: controller.failure) { failure in
      Button("Try Again") { controller.perform(failure.action, didChangeDisplay: didChangeDisplay) }
      Button("Cancel", role: .cancel) {}
    } message: { failure in Text(failure.message) }
  }

  @ViewBuilder
  private func menu(
    _ title: String,
    actions: [EmulatorControlAction],
    selected: EmulatorControlAction?,
    fallbackSymbol: String
  ) -> some View {
    if !actions.isEmpty {
      Menu {
        ForEach(actions, id: \.self) { action in
          Toggle(isOn: Binding(
            get: { selected == action },
            set: { if $0 { controller.perform(action, didChangeDisplay: didChangeDisplay) } }
          )) {
            Label(action.title, systemImage: action.symbol)
          }
        }
      } label: {
        icon(selected?.symbol ?? fallbackSymbol)
          .overlay(alignment: .trailing) {
            Image(systemName: "chevron.down")
              .font(.system(size: 8, weight: .semibold))
              .foregroundStyle(.secondary)
          }
      }
      .menuStyle(.button)
      .menuIndicator(.hidden)
      .fixedSize()
      .help(title)
      .accessibilityLabel(title)
      .accessibilityValue(selected?.title ?? "Unknown")
      .disabled(controller.pendingAction != nil)
    }
  }

  private func icon(_ symbol: String, verticalOffset: CGFloat = 0) -> some View {
    Image(systemName: symbol)
      .font(.system(size: 15, weight: .regular))
      .foregroundStyle(.primary)
      .offset(y: verticalOffset)
      .frame(width: 32, height: 36)
      .contentShape(Rectangle())
  }
}

private extension EmulatorControlAction {
  var failureTitle: String {
    switch self {
    case .phone, .foldable, .tablet, .desktop: "Couldn’t Switch to \(title) Mode"
    case .closed, .halfOpen, .open: "Couldn’t Change Posture to \(title)"
    }
  }

  var symbol: String {
    switch self {
    case .phone: "iphone"
    case .foldable, .open: "rectangle.split.2x1"
    case .tablet: "ipad.landscape"
    case .desktop: "display"
    case .closed: "book.closed"
    case .halfOpen: "book"
    }
  }

  var title: String {
    switch self {
    case .phone: "Phone"
    case .foldable: "Foldable"
    case .tablet: "Tablet"
    case .desktop: "Desktop"
    case .closed: "Closed"
    case .halfOpen: "Half-Closed"
    case .open: "Open"
    }
  }
}
