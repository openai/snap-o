import AppKit
import SwiftUI

@MainActor
private protocol SnapOCommandTarget: AnyObject {
  func perform(_ command: SnapOCommand)
}

@MainActor
final class SnapOCommandCoordinator {
  static let shared = SnapOCommandCoordinator()

  private weak var focusedTarget: (any SnapOCommandTarget)?
  private var pendingCommands: [SnapOCommand] = []

  private init() {}

  func handle(url: URL) -> Bool {
    guard url.scheme?.lowercased() == "snapo" else { return false }
    guard let command = SnapOCommand.from(url: url) else { return false }
    if let focusedTarget {
      focusedTarget.perform(command)
    } else {
      pendingCommands.append(command)
    }
    return true
  }

  fileprivate func activate(_ target: any SnapOCommandTarget) {
    focusedTarget = target
    let commands = pendingCommands
    pendingCommands.removeAll()
    for command in commands {
      target.perform(command)
    }
  }

  fileprivate func deactivate(_ target: any SnapOCommandTarget) {
    guard focusedTarget === target else { return }
    focusedTarget = nil
  }
}

extension SnapOCommand {
  static func from(url: URL) -> SnapOCommand? {
    let host = url.host?.lowercased() ?? ""
    let pathComponent = url.pathComponents.dropFirst().first?.lowercased() ?? ""
    let token = host.isEmpty ? pathComponent : host
    return SnapOCommand(rawValue: token)
  }
}

struct WindowCommandRegistration: NSViewRepresentable {
  let perform: @MainActor (SnapOCommand) -> Void

  func makeNSView(context: Context) -> WindowCommandTargetView {
    WindowCommandTargetView(perform: perform)
  }

  func updateNSView(_ nsView: WindowCommandTargetView, context: Context) {
    nsView.performCommand = perform
    nsView.attach(to: nsView.window)
  }

  static func dismantleNSView(_ nsView: WindowCommandTargetView, coordinator: ()) {
    nsView.detach()
  }
}

@MainActor
final class WindowCommandTargetView: NSView, SnapOCommandTarget {
  var performCommand: @MainActor (SnapOCommand) -> Void

  private weak var observedWindow: NSWindow?
  private var notificationTokens: [NSObjectProtocol] = []

  init(perform: @escaping @MainActor (SnapOCommand) -> Void) {
    performCommand = perform
    super.init(frame: .zero)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    nil
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    attach(to: window)
  }

  func perform(_ command: SnapOCommand) {
    performCommand(command)
  }

  func attach(to window: NSWindow?) {
    guard observedWindow !== window else {
      if window?.isKeyWindow == true {
        SnapOCommandCoordinator.shared.activate(self)
      }
      return
    }

    detach()
    guard let window else { return }
    observedWindow = window

    let center = NotificationCenter.default
    notificationTokens = [
      center.addObserver(
        forName: NSWindow.didBecomeKeyNotification,
        object: window,
        queue: .main
      ) { [weak self] _ in
        guard let self else { return }
        MainActor.assumeIsolated {
          SnapOCommandCoordinator.shared.activate(self)
        }
      },
      center.addObserver(
        forName: NSWindow.didResignKeyNotification,
        object: window,
        queue: .main
      ) { [weak self] _ in
        guard let self else { return }
        MainActor.assumeIsolated {
          SnapOCommandCoordinator.shared.deactivate(self)
        }
      },
      center.addObserver(
        forName: NSWindow.willCloseNotification,
        object: window,
        queue: .main
      ) { [weak self] _ in
        guard let self else { return }
        MainActor.assumeIsolated {
          self.detach()
        }
      }
    ]

    if window.isKeyWindow {
      SnapOCommandCoordinator.shared.activate(self)
    }
  }

  func detach() {
    SnapOCommandCoordinator.shared.deactivate(self)
    for token in notificationTokens {
      NotificationCenter.default.removeObserver(token)
    }
    notificationTokens.removeAll()
    observedWindow = nil
  }
}
