import AppKit
import SwiftUI

struct WindowFocusReader: NSViewRepresentable {
  let focusDidChange: (Bool) -> Void

  func makeNSView(context: Context) -> WindowFocusReaderView {
    WindowFocusReaderView(focusDidChange: focusDidChange)
  }

  func updateNSView(_ view: WindowFocusReaderView, context: Context) {
    view.focusDidChange = focusDidChange
  }

  static func dismantleNSView(_ view: WindowFocusReaderView, coordinator: ()) {
    view.detach()
  }
}

@MainActor
final class WindowFocusReaderView: NSView {
  var focusDidChange: (Bool) -> Void
  private let isAppActive: () -> Bool
  private var observers: [NSObjectProtocol] = []

  init(isAppActive: @escaping () -> Bool = { NSApp.isActive }, focusDidChange: @escaping (Bool) -> Void) {
    self.isAppActive = isAppActive
    self.focusDidChange = focusDidChange
    super.init(frame: .zero)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    detach()
    guard let window else { return }
    let center = NotificationCenter.default
    for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
      observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated { self?.updateFocus() }
      })
    }
    for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
      observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated { self?.updateFocus() }
      })
    }
    observers.append(center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated { self?.detach() }
    })
    updateFocus()
  }

  func detach() {
    for observer in observers {
      NotificationCenter.default.removeObserver(observer)
    }
    observers.removeAll()
    focusDidChange(false)
  }

  private func updateFocus() {
    focusDidChange(isAppActive() && window?.isKeyWindow == true)
  }
}
