import AppKit
import SwiftUI

/// Keeps the capture window title centered against the full titlebar instead
/// of AppKit's remaining title slot after toolbar items are laid out.
struct WindowTitleController: NSViewRepresentable {
  let title: String

  func makeCoordinator() -> Coordinator {
    Coordinator()
  }

  func makeNSView(context: Context) -> NSView {
    let view = NSView()
    DispatchQueue.main.async {
      context.coordinator.configure(window: view.window, title: title)
    }
    return view
  }

  func updateNSView(_ nsView: NSView, context: Context) {
    context.coordinator.configure(window: nsView.window, title: title)
  }

  @MainActor
  final class Coordinator: NSObject {
    private weak var window: NSWindow?
    private let titleLabel = NSTextField(labelWithString: "")

    override init() {
      super.init()
      titleLabel.translatesAutoresizingMaskIntoConstraints = false
      titleLabel.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
      titleLabel.lineBreakMode = .byTruncatingMiddle
      titleLabel.maximumNumberOfLines = 1
      titleLabel.alignment = .center
      titleLabel.isSelectable = false
    }

    func configure(window: NSWindow?, title: String) {
      guard let window else { return }

      if self.window !== window {
        attach(to: window)
      }

      window.title = title
      titleLabel.stringValue = title
      installTitleLabel(in: window)
    }

    private func attach(to window: NSWindow) {
      if let currentWindow = self.window {
        stopObservingTitlebarChanges(for: currentWindow)
      }

      self.window = window
      window.titleVisibility = .hidden
      observeTitlebarChanges(for: window)
    }

    private func installTitleLabel(in window: NSWindow) {
      guard
        let closeButton = window.standardWindowButton(.closeButton),
        let titlebarView = closeButton.superview
      else {
        return
      }

      guard titleLabel.superview !== titlebarView else { return }
      titleLabel.removeFromSuperview()
      titlebarView.addSubview(titleLabel)

      NSLayoutConstraint.activate([
        titleLabel.centerXAnchor.constraint(equalTo: titlebarView.centerXAnchor),
        titleLabel.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor),
        titleLabel.leadingAnchor.constraint(greaterThanOrEqualTo: titlebarView.leadingAnchor, constant: 76),
        titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: titlebarView.trailingAnchor, constant: -76)
      ])
    }

    private func observeTitlebarChanges(for window: NSWindow) {
      NotificationCenter.default.addObserver(
        self,
        selector: #selector(titlebarHierarchyDidChange(_:)),
        name: NSWindow.didEnterFullScreenNotification,
        object: window
      )
      NotificationCenter.default.addObserver(
        self,
        selector: #selector(titlebarHierarchyDidChange(_:)),
        name: NSWindow.didExitFullScreenNotification,
        object: window
      )
    }

    private func stopObservingTitlebarChanges(for window: NSWindow) {
      NotificationCenter.default.removeObserver(
        self,
        name: NSWindow.didEnterFullScreenNotification,
        object: window
      )
      NotificationCenter.default.removeObserver(
        self,
        name: NSWindow.didExitFullScreenNotification,
        object: window
      )
    }

    @objc
    private func titlebarHierarchyDidChange(_ notification: Notification) {
      guard let window = notification.object as? NSWindow else { return }
      installTitleLabel(in: window)
    }
  }
}
