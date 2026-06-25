import AppKit
import Observation
import SwiftUI

struct NetworkInspectorToolbarControls: View {
  @Bindable var model: NetworkInspectorHostModel
  @Binding var isSearchPresented: Bool

  private var sortHelp: String {
    model.sortNewestFirst
      ? "Sorted newest first. Show oldest first"
      : "Sorted oldest first. Show newest first"
  }

  var body: some View {
    HStack(spacing: 8) {
      HStack(spacing: 0) {
        Button {
          model.clearCompletedRecords()
        } label: {
          Label("Clear Completed Requests", systemImage: "trash")
            .labelStyle(.iconOnly)
            .font(.system(size: 15, weight: .medium))
            .frame(width: 34, height: 32)
        }
        .help("Clear completed requests")
        .disabled(!model.hasClearableItems)

        Button {
          model.setSortNewestFirst(!model.sortNewestFirst)
        } label: {
          Label(
            model.sortNewestFirst ? "Newest First" : "Oldest First",
            systemImage: model.sortNewestFirst ? "arrow.down" : "arrow.up"
          )
          .labelStyle(.iconOnly)
          .font(.system(size: 15, weight: .medium))
          .frame(width: 34, height: 32)
        }
        .help(sortHelp)

        if !isSearchPresented {
          Button {
            isSearchPresented = true
          } label: {
            Label("Filter Requests", systemImage: "magnifyingglass")
              .labelStyle(.iconOnly)
              .font(.system(size: 15, weight: .medium))
              .frame(width: 34, height: 32)
          }
          .help("Filter requests (⌘F)")
          .keyboardShortcut("f", modifiers: .command)
          .transition(.opacity)
        }
      }
      .snapOToolbarGroupStyle()

      if isSearchPresented {
        NetworkInspectorSearchField(
          text: Binding(
            get: { model.searchText },
            set: { model.setSearchText($0) }
          )
        ) {
          isSearchPresented = false
        }
        .transition(
          .modifier(
            active: NetworkInspectorSearchTransition(progress: 0),
            identity: NetworkInspectorSearchTransition(progress: 1)
          )
        )
      }
    }
    .disabled(!model.isPageReady)
    .onAppear {
      if !model.searchText.isEmpty {
        isSearchPresented = true
      }
    }
    .onChange(of: model.searchText) {
      if !model.searchText.isEmpty {
        isSearchPresented = true
      }
    }
  }
}

private struct NetworkInspectorSearchTransition: ViewModifier {
  let progress: CGFloat

  func body(content: Content) -> some View {
    content
      .frame(width: 220 * progress, height: 28, alignment: .leading)
      .clipped()
      .opacity(progress)
  }
}

private struct NetworkInspectorSearchField: NSViewRepresentable {
  @Binding var text: String
  let dismiss: () -> Void

  func makeCoordinator() -> Coordinator {
    Coordinator(text: $text, dismiss: dismiss)
  }

  func makeNSView(context: Context) -> FocusedSearchField {
    let searchField = FocusedSearchField(string: text)
    searchField.placeholderString = "Filter requests"
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
