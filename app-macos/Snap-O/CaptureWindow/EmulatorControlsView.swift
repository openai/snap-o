import SwiftUI

struct EmulatorControlsView: View {
  let serial: String
  var isVertical = false
  let didChangeDisplay: () -> Void
  @State private var client = EmulatorClient()
  @State private var controls: EmulatorControls?
  @State private var pendingAction: EmulatorControlAction?
  @State private var failure: (action: EmulatorControlAction, message: String)?

  var body: some View {
    let stack = isVertical ? AnyLayout(VStackLayout(spacing: 4)) : AnyLayout(HStackLayout(spacing: 4))
    stack {
      button(.rotateLeft)
      button(.rotateRight)
      if let controls {
        menu("Display Mode", actions: controls.displayModes.map(\.action), selected: controls.currentDisplayMode, fallbackSymbol: "display")
        menu("Posture", actions: controls.postures, selected: controls.currentPosture, fallbackSymbol: "questionmark.square")
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Emulator controls")
    .task(id: serial) {
      await loadControls()
    }
    .task(id: pendingAction) {
      guard let action = pendingAction, let controls else { return }
      do {
        try await client.control(serial: serial, avdPath: controls.avdPath, action: action)
        try Task.checkCancellation()
        didChangeDisplay()
        await loadControls()
      } catch {
        if !Task.isCancelled { failure = (action, error.localizedDescription) }
      }
      if !Task.isCancelled { pendingAction = nil }
    }
    .onDisappear {
      client.close()
      pendingAction = nil
      controls = nil
      failure = nil
    }
    .alert(failure?.action.failureTitle ?? "Emulator Controls", isPresented: Binding(
      get: { failure != nil },
      set: { if !$0 { failure = nil } }
    ), presenting: failure) { failure in
      Button("Try Again") {
        pendingAction = failure.action
      }
      Button("Cancel", role: .cancel) {}
    } message: { failure in Text(failure.message) }
  }

  private func loadControls() async {
    var delay = 1
    while !Task.isCancelled {
      do {
        let result = try await client.controls(serial: serial)
        try Task.checkCancellation()
        controls = result
        return
      } catch {
        guard !Task.isCancelled else { return }
        // Preview can start before Android's window service is ready.
        controls = nil
        do { try await Task.sleep(for: .seconds(delay)) } catch { return }
        delay = min(delay * 2, 5)
      }
    }
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
            set: { if $0 { pendingAction = action } }
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
      .disabled(pendingAction != nil)
    }
  }

  private func button(_ action: EmulatorControlAction) -> some View {
    Button {
      pendingAction = action
    } label: {
      // Align the device outline, allowing for the arrow above it.
      icon(action.symbol, verticalOffset: -2)
    }
    .help(action.title)
    .accessibilityLabel(action.title)
    .disabled(pendingAction != nil || controls?.actions.contains(action) != true)
  }

  private func icon(_ symbol: String, verticalOffset: CGFloat = 0) -> some View {
    Image(systemName: symbol)
      .resizable()
      .scaledToFit()
      .frame(width: 15, height: 15)
      .foregroundStyle(.primary)
      .offset(y: verticalOffset)
      .frame(width: 32, height: 36)
      .contentShape(Rectangle())
  }
}

private extension EmulatorControlAction {
  var failureTitle: String {
    switch self {
    case .rotateLeft: "Couldn’t Rotate Emulator Left"
    case .rotateRight: "Couldn’t Rotate Emulator Right"
    case .phone, .foldable, .tablet, .desktop: "Couldn’t Switch to \(title) Mode"
    case .closed, .halfOpen, .open: "Couldn’t Change Posture to \(title)"
    }
  }

  var symbol: String {
    switch self {
    case .rotateLeft: "rotate.left"
    case .rotateRight: "rotate.right"
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
    case .rotateLeft: "Rotate Left"
    case .rotateRight: "Rotate Right"
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
