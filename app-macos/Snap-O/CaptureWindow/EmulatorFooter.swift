import SwiftUI

struct EmulatorFooter: View {
  static let height: CGFloat = 44

  let serial: String
  let didChangeDisplay: () -> Void
  @State private var client = EmulatorClient()
  @State private var controls: EmulatorControls?
  @State private var pendingAction: EmulatorControlAction?
  @State private var failure: (action: EmulatorControlAction?, message: String)?
  @State private var reloadID = UUID()

  var body: some View {
    HStack(spacing: 8) {
      button(.rotateLeft)
      button(.rotateRight)
      if let controls {
        if !controls.displayModes.isEmpty || !controls.postures.isEmpty {
          Divider().frame(height: 14)
        }
        menu("Display Mode", actions: controls.displayModes.map(\.action), selected: controls.currentDisplayMode, fallbackSymbol: "display")
        menu("Posture", actions: controls.postures, selected: controls.currentPosture, fallbackSymbol: "questionmark.square")
      }
    }
    .buttonStyle(.plain)
    .controlSize(.regular)
    .padding(.horizontal, 10)
    .frame(maxWidth: .infinity)
    .frame(height: Self.height)
    .background(.bar)
    .overlay(alignment: .top) { Divider() }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Emulator controls")
    .task(id: reloadID) {
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
    .alert(failure?.action?.failureTitle ?? "Couldn’t Load Emulator Controls", isPresented: Binding(
      get: { failure != nil },
      set: { if !$0 { failure = nil } }
    ), presenting: failure) { failure in
      Button("Try Again") {
        if let action = failure.action {
          pendingAction = action
        } else {
          reloadID = UUID()
        }
      }
      Button("Cancel", role: .cancel) {}
    } message: { failure in Text(failure.message) }
  }

  private func loadControls() async {
    do {
      let result = try await client.controls(serial: serial)
      try Task.checkCancellation()
      controls = result
    } catch {
      if !Task.isCancelled { failure = (nil, error.localizedDescription) }
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
        HStack(spacing: 2) {
          icon(selected?.symbol ?? fallbackSymbol)
          Image(systemName: "chevron.down")
            .font(.system(size: 9, weight: .semibold))
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
      .frame(width: 18, height: 18)
      .foregroundStyle(.secondary)
      .offset(y: verticalOffset)
      .frame(width: 32, height: 32)
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
