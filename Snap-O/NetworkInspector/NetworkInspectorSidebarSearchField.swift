import AppKit
import SwiftUI

struct NetworkInspectorSidebarSearchField: NSViewRepresentable {
  @Binding var text: String
  var onMoveSelection: (Int) -> Void

  func makeCoordinator() -> Coordinator {
    Coordinator(text: $text, onMoveSelection: onMoveSelection)
  }

  func makeNSView(context: Context) -> ArrowHandlingSearchField {
    let searchField = ArrowHandlingSearchField()
    searchField.placeholderString = "Filter by URL"
    searchField.focusRingType = .none
    searchField.delegate = context.coordinator
    searchField.stringValue = text
    searchField.moveSelection = { direction in
      context.coordinator.moveSelection(by: direction)
    }
    return searchField
  }

  func updateNSView(_ nsView: ArrowHandlingSearchField, context: Context) {
    if nsView.stringValue != text {
      nsView.stringValue = text
    }
  }

  final class Coordinator: NSObject, NSSearchFieldDelegate {
    @Binding var text: String
    private let onMoveSelection: (Int) -> Void

    init(text: Binding<String>, onMoveSelection: @escaping (Int) -> Void) {
      _text = text
      self.onMoveSelection = onMoveSelection
    }

    func controlTextDidChange(_ notification: Notification) {
      guard let field = notification.object as? NSSearchField else { return }
      text = field.stringValue
    }

    func moveSelection(by offset: Int) {
      onMoveSelection(offset)
    }
  }

  final class ArrowHandlingSearchField: NSSearchField {
    var moveSelection: ((Int) -> Void)?

    override func keyDown(with event: NSEvent) {
      let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
      if modifiers.isDisjoint(with: [.command, .option, .control]) {
        switch event.keyCode {
        case 125: // down arrow
          moveSelection?(1)
          return
        case 126: // up arrow
          moveSelection?(-1)
          return
        default:
          break
        }
      }

      super.keyDown(with: event)
    }
  }
}
