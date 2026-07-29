import AppKit
import Observation
import SwiftUI

struct NetworkInspectorToolbarControls: View {
  @Bindable var model: NetworkInspectorHostModel
  @Binding var isSearchPresented: Bool
  @State private var isHostFilterPresented = false

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

        Button {
          isHostFilterPresented.toggle()
        } label: {
          Label("Manage Hidden Hosts", systemImage: "line.3.horizontal.decrease.circle")
            .labelStyle(.iconOnly)
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(model.hiddenHosts.isEmpty ? Color.primary : Color.accentColor)
            .frame(width: 34, height: 32)
            .overlay(alignment: .topTrailing) {
              if !model.hiddenHosts.isEmpty {
                Text(model.hiddenHosts.count > 99 ? "99+" : "\(model.hiddenHosts.count)")
                  .font(.system(size: 9, weight: .semibold))
                  .monospacedDigit()
                  .foregroundStyle(.white)
                  .padding(.horizontal, 3)
                  .frame(minWidth: 14, minHeight: 14)
                  .background(Color.accentColor, in: Capsule())
                  .offset(x: -2, y: 2)
                  .allowsHitTesting(false)
                  .accessibilityHidden(true)
              }
            }
        }
        .help(hostFilterHelp)
        .popover(isPresented: $isHostFilterPresented, arrowEdge: .bottom) {
          NetworkInspectorHostFilterPopover(model: model)
        }

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

  private var hostFilterHelp: String {
    let count = model.hiddenHosts.count
    guard count > 0 else { return "Manage permanently hidden hosts" }
    return "Manage permanently hidden hosts (\(count) active \(count == 1 ? "filter" : "filters"))"
  }
}

private struct NetworkInspectorHostFilterPopover: View {
  @Bindable var model: NetworkInspectorHostModel

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      VStack(alignment: .leading, spacing: 4) {
        Text("Hidden Hosts")
          .font(.system(size: 13, weight: .semibold))

        Text("Right-click on any request and click \"Add to filtered hosts\".")
          .font(.system(size: 12))
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }

      if model.hiddenHosts.isEmpty {
        Text("No hidden hosts")
          .font(.system(size: 12))
          .foregroundStyle(.secondary)
      } else {
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 4) {
            ForEach(model.hiddenHosts, id: \.self) { host in
              HStack(spacing: 8) {
                Text(host)
                  .font(.system(size: 12))
                  .lineLimit(1)
                  .frame(maxWidth: .infinity, alignment: .leading)

                Button {
                  model.removeHiddenHost(host)
                } label: {
                  Label("Show \(host) Again", systemImage: "xmark.circle.fill")
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Show requests to \(host) again")
              }
              .padding(.vertical, 4)
            }
          }
        }
        .frame(maxHeight: 200)
      }
    }
    .padding(14)
    .frame(width: 340, alignment: .leading)
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
