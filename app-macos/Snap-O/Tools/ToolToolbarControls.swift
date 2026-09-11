import AppKit
import Observation
import SwiftUI

struct ToolToolbarControls: View {
  @Bindable var model: PluginHostModel
  @Binding var isSearchPresented: Bool

  var placement: ToolToolbarAction.Placement = .start

  private var actions: [ToolToolbarAction] {
    model.toolbarActions.filter { $0.position == placement }
  }

  var body: some View {
    HStack(spacing: 8) {
      if !actions.isEmpty {
        HStack(spacing: 0) {
          ForEach(actions) { action in
            if action.type == .button {
              Button { model.activateToolbarAction(action.id) } label: {
                Label(action.label, systemImage: action.icon?.symbol ?? "questionmark")
                  .labelStyle(.iconOnly)
                  .font(SnapOToolbarStyle.iconFont)
                  .frame(width: 34, height: 32)
              }
              .help(action.label)
              .disabled(action.enabled == false)
            } else {
              Button { isSearchPresented.toggle() } label: {
                Label(action.label, systemImage: "magnifyingglass").labelStyle(.iconOnly)
                  .font(SnapOToolbarStyle.iconFont)
                  .frame(width: 34, height: 32)
              }
              .help(action.label)
              .keyboardShortcut("f", modifiers: .command)
              .disabled(action.enabled == false)
            }
          }
        }
        .controlSize(.extraLarge)
        .snapOToolbarGroupStyle()
      }
      if isSearchPresented, let search = actions.first(where: { $0.type == .search }) {
        ToolSearchField(
          text: Binding(
            get: { search.value ?? "" },
            set: { model.activateToolbarAction(search.id, value: $0) }
          ),
          label: search.label
        ) { isSearchPresented = false }
          .frame(width: 220)
          .disabled(search.enabled == false)
      }
    }
    .frame(minWidth: placement == .start ? 110 : nil, alignment: .trailing)
    .disabled(!model.isPageReady)
  }
}

private struct ToolSearchField: NSViewRepresentable {
  @Binding var text: String
  let label: String
  let dismiss: () -> Void

  func makeCoordinator() -> Coordinator {
    Coordinator(text: $text, dismiss: dismiss)
  }

  func makeNSView(context: Context) -> FocusedSearchField {
    let searchField = FocusedSearchField(string: text)
    searchField.placeholderString = label
    searchField.sendsSearchStringImmediately = true
    searchField.sendsWholeSearchString = true
    searchField.delegate = context.coordinator
    searchField.bezelStyle = .roundedBezel
    searchField.controlSize = .large
    return searchField
  }

  func updateNSView(_ nsView: FocusedSearchField, context: Context) {
    context.coordinator.text = $text
    context.coordinator.dismiss = dismiss
    if nsView.stringValue != text {
      nsView.stringValue = text
    }
  }

  final class Coordinator: NSObject, NSSearchFieldDelegate {
    var text: Binding<String>
    var dismiss: () -> Void

    init(text: Binding<String>, dismiss: @escaping () -> Void) {
      self.text = text
      self.dismiss = dismiss
    }

    func controlTextDidChange(_ notification: Notification) {
      guard let field = notification.object as? NSSearchField else { return }
      text.wrappedValue = field.stringValue
    }

    func control(
      _ control: NSControl,
      textView: NSTextView,
      doCommandBy commandSelector: Selector
    ) -> Bool {
      guard commandSelector == #selector(NSResponder.cancelOperation(_:)),
            let field = control as? NSSearchField
      else {
        return false
      }

      if field.stringValue.isEmpty {
        dismiss()
      } else {
        field.stringValue = ""
        text.wrappedValue = ""
      }
      return true
    }
  }
}

private final class FocusedSearchField: NSSearchField {
  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    guard window != nil else { return }
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      window?.makeFirstResponder(self)
    }
  }
}
