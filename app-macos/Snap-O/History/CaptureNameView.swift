import AppKit
import SwiftUI

struct CaptureNameButton: View {
  let entry: CaptureHistoryEntry
  let rename: (String) -> Void
  @State private var isRenaming = false

  var body: some View {
    Button { isRenaming = true } label: {
      HStack(spacing: 4) {
        Text(entry.displayName)
          .foregroundStyle(entry.name == nil ? .tertiary : .primary)
          .lineLimit(1)
          .truncationMode(.tail)
        Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help("Rename capture")
    .accessibilityLabel("Rename capture: \(entry.displayName)")
    .popover(isPresented: $isRenaming) {
      CaptureNamePopover(name: entry.name ?? "", rename: rename)
    }
    .onChange(of: entry.id) { isRenaming = false }
  }
}

private struct CaptureNamePopover: View {
  @State var name: String
  let rename: (String) -> Void
  @Environment(\.dismiss)
  private var dismiss
  @FocusState private var isFocused: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Capture name").font(.headline)
      TextField("", text: $name)
        .textFieldStyle(.roundedBorder)
        .accessibilityLabel("Capture name")
        .focused($isFocused)
        .onSubmit(save)
      HStack {
        Spacer()
        Button("Cancel") { dismiss() }
        Button("Save", action: save).keyboardShortcut(.defaultAction)
      }
      .buttonStyle(.bordered)
    }
    .font(.body)
    .controlSize(.regular)
    .padding(16)
    .frame(width: 280)
    .background(CaptureRenameEscapeHandler { dismiss() })
    .onAppear { isFocused = true }
  }

  private func save() {
    rename(name)
    dismiss()
  }
}

private struct CaptureRenameEscapeHandler: NSViewRepresentable {
  let dismiss: () -> Void

  func makeNSView(context: Context) -> EscapeView {
    EscapeView()
  }

  func updateNSView(_ view: EscapeView, context: Context) {
    view.dismiss = dismiss
  }

  static func dismantleNSView(_ view: EscapeView, coordinator: ()) {
    view.stopMonitoring()
  }

  @MainActor
  final class EscapeView: NSView {
    var dismiss: (() -> Void)?
    private var eventMonitor: Any?

    override func hitTest(_ point: NSPoint) -> NSView? {
      nil
    }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      stopMonitoring()
      guard window != nil else { return }
      eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
        guard let self, let window, event.keyCode == 53,
              event.window === window || event.window === window.parent || window.isKeyWindow else { return event }
        // Consume Escape before dismissing the popover can return focus to history.
        dismiss?()
        return nil
      }
    }

    func stopMonitoring() {
      if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
      eventMonitor = nil
    }
  }
}

struct CaptureHistoryName: View {
  let entry: CaptureHistoryEntry
  @Binding var isEditing: Bool
  let rename: (String) -> Void

  var body: some View {
    Group {
      if isEditing {
        CaptureHistoryNameField(entry: entry, isEditing: $isEditing, rename: rename)
      } else {
        Text(entry.displayName)
          .font(.system(size: NSFont.smallSystemFontSize))
          .foregroundStyle(entry.name == nil ? .tertiary : .primary)
          .lineLimit(1)
      }
    }
    .frame(height: 18)
    .help("Rename using the context menu")
    .accessibilityAction(named: "Rename") { isEditing = true }
  }
}

private struct CaptureHistoryNameField: NSViewRepresentable {
  let entry: CaptureHistoryEntry
  @Binding var isEditing: Bool
  let rename: (String) -> Void

  func makeCoordinator() -> Coordinator {
    Coordinator(self)
  }

  func makeNSView(context: Context) -> NSTextField {
    let field = CaptureHistoryRenameField()
    field.controlSize = .small
    field.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
    field.alignment = .center
    field.lineBreakMode = .byTruncatingTail
    field.maximumNumberOfLines = 1
    field.usesSingleLineMode = true
    field.textColor = .labelColor
    field.backgroundColor = .textBackgroundColor
    field.focusRingType = .exterior
    field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    field.setAccessibilityLabel("Capture name")
    field.delegate = context.coordinator
    return field
  }

  func updateNSView(_ field: NSTextField, context: Context) {
    context.coordinator.parent = self
    if isEditing { context.coordinator.beginEditing(field) }
  }

  @MainActor
  final class Coordinator: NSObject, NSTextFieldDelegate {
    var parent: CaptureHistoryNameField
    private(set) var isEditing = false

    init(_ parent: CaptureHistoryNameField) {
      self.parent = parent
    }

    func beginEditing(_ field: NSTextField) {
      guard !isEditing else { return }
      isEditing = true
      field.stringValue = parent.entry.name ?? ""
      field.textColor = .labelColor
      field.isEditable = true
      field.isSelectable = true
      field.isBezeled = true
      field.drawsBackground = true
    }

    func controlTextDidEndEditing(_ notification: Notification) {
      guard let field = notification.object as? NSTextField else { return }
      finishEditing(field, save: true)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
      guard commandSelector == #selector(NSResponder.cancelOperation(_:)),
            let field = control as? NSTextField else { return false }
      finishEditing(field, save: false)
      return true
    }

    private func finishEditing(_ field: NSTextField, save: Bool) {
      guard isEditing else { return }
      let name = field.stringValue
      isEditing = false
      parent.isEditing = false
      field.abortEditing()
      if save { parent.rename(name) }
    }
  }
}

private final class CaptureHistoryRenameField: NSTextField {
  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    guard window != nil else { return }
    // The field is created during Rename; wait for attachment and menu dismissal before focusing it.
    DispatchQueue.main.async { [weak self] in
      guard let self, window != nil else { return }
      selectText(nil)
    }
  }
}
